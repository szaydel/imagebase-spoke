#!/bin/bash
set -e

# Tunable variables
SPOKE_DETACH_MODE=${SPOKE_DETACH_MODE:-"False"}
# For special-case server stand alone mode; will run without a hub container.
# This mode is fussy and only for special cases that truly need to be run
# as an individual container.
SUPERVISOR_REPO=${SUPERVISOR_REPO:-"https://github.com/radial/config-supervisor.git"}
SUPERVISOR_BRANCH=${SUPERVISOR_BRANCH:-"master"}
WHEEL_REPO=${WHEEL_REPO:-""}
WHEEL_BRANCH=${WHEEL_BRANCH:-"config"}
SPOKE_CMD=${SPOKE_CMD:-""}

# Misc settings 
APP_GROUP="$SPOKE_NAME-group"

pull_wheel_config() {
    remoteName=$(date | md5sum | head -c10)
    git remote add ${remoteName} ${WHEEL_REPO}
    git pull --no-edit ${remoteName} ${WHEEL_BRANCH}
}

apply_permissions() {
    # Set file and folder permissions for all configuration and uploaded
    # files.

    do_apply() {
        if [ "$(find "$1" -type d -not -path "*/.git*")" ]; then
            find "$1" -type d -not -path "*/.git*" -print0 | xargs -0 chmod 755
            if [ "$(find "$1" -type f -not -path "*/.git*")" ]; then
                find "$1" -type f -not -path "*/.git*" -print0 | xargs -0 chmod 644
            fi
            echo "...file permissions successfully applied to $1."
        fi
    }

    if [ -d /config ]; then
        do_apply /config
    fi
    if [ -d /data ]; then
        do_apply /data
    fi
    if [ -d /log ]; then
        do_apply /log
    fi
}

run_spoke_checks() {
    if [ -z $SPOKE_NAME ]; then
        echo "Error: SPOKE_NAME variable not set in Dockerfile. Supervisor doesn't know what to start."
        exit 1
    fi
    if [ "$SPOKE_DETACH_MODE" = "False" ]; then
        if [ ! -d /config ]; then
            echo "Error: No Hub container detected."
            exit 1
        fi

        # Wait until the Hub container is done loading all configuration.
        echo "Spoke \"$SPOKE_NAME\" is waiting for Hub container to load..."
        while [ -d /run/hub.lock ]; do
            sleep 1s
        done
        echo "Hub container loaded. Continuing to load Spoke \"$SPOKE_NAME\"."
    elif [ "$WHEEL_REPO" = "" ]; then
            echo "Warning: \"Spoke-detach\" mode is enabled, but the \`\$WHEEL_REPO\` variable is not set. This Spoke will not pull any configuration."
    else
        if [ ! $(which git) ]; then
            echo "git is required for \"Spoke-detach\" mode. Please install it in your Spoke Dockerfile."
            exit 1
        fi
        if [ -d /config ]; then
            echo "\"Spoke-detach\" mode cannot run with \`--volumes-from\` any hub containers."
            exit 1
        fi
    fi
}

do_first_run_tasks() {
    # Setup configuration in spoke-detach mode only
    if [ "$SPOKE_DETACH_MODE" = "True" ]; then
        # Clone supervisor skeleton
        echo "cloning Supervisor skeleton config..."
        git clone $SUPERVISOR_REPO -b $SUPERVISOR_BRANCH /config &&
            echo "...done"
        mkdir -p /data /log
        cd /config
        if [ "$WHEEL_REPO" != "" ]; then
            pull_wheel_config
        fi
        apply_permissions 
    fi

    # Make unique directory for logs
    mkdir -p /log/$HOSTNAME

    # Make unique directory for Supervisor runtime files
    mkdir -p /run/supervisor/$HOSTNAME

    # To easily see which program the Supervisor runtime files belong to.
    touch /run/supervisor/$HOSTNAME/$SPOKE_NAME

    # Here we trick Supervisor into storing it's socket and pid files in a
    # dynamic directory.  The supervisor.conf file doesn't allow use of
    # %(host_node_name)s when defining a pid or socketfile. But we want that,
    # so we use $(here)s which uses the location of the configuration file
    # itself.
    ln -sf /config/supervisor/supervisord.conf /run/supervisor/$HOSTNAME/supervisord.conf
}

start_normal() {
    # The following programs need to be run after supervisor starts, however,
    # we need to run supervisor last because of `exec` in this script. So we run
    # them with a delay until after supervisor claims PID 1 through exec.

    # Start this spoke's program group
    /bin/sh -c "while [ ! -e /run/supervisor/$HOSTNAME/supervisord.pid ]; do sleep 1s; done &&
        supervisorctl -s unix:///run/supervisor/$HOSTNAME/supervisor.sock start $APP_GROUP:*" &

    # Copy errors to main log for easy debugging with `docker logs` if errors occur
    # preventing application startup. No need to include normal output here
    # because a real log management solution should be in place for that.
    /bin/sh -c "while [ ! -e /log/$HOSTNAME/${SPOKE_NAME}_stderr.log ]; do sleep 1s; done &&
                tail --follow=name -c +0 /log/$HOSTNAME/*_stderr.log |
                tee -a /log/$HOSTNAME/supervisord.log" &

    exec supervisord \
        --configuration=/run/supervisor/$HOSTNAME/supervisord.conf \
        --logfile=/log/$HOSTNAME/supervisord.log
}

if [ $# -eq 0 ]; then
    if [ ! -e /tmp/first_run ]; then
        touch /tmp/first_run

        run_spoke_checks
        do_first_run_tasks
    fi

    start_normal

elif [ "$SPOKE_CMD" != "" ]; then
    /bin/sh -c "exec ${SPOKE_CMD} $(echo "$@")"
else
    /bin/sh -c "exec $(echo "$@")"
fi
