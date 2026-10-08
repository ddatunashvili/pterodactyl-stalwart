#!/bin/bash
cd /home/container || exit 1

# Everything Stalwart keeps: its one-line store pointer, the RocksDB data
# (which holds every other setting), logs, and the web UI it unpacks.
mkdir -p /home/container/etc /home/container/data /home/container/logs /home/container/tmp
export TMPDIR=/home/container/tmp

CONFIG=/home/container/etc/config.json
STALWART=/usr/local/bin/stalwart

SMTP_PORT="${SERVER_PORT:-2525}"
SUBMISSION_PORT="${SUBMISSION_PORT:-2587}"
SUBMISSIONS_PORT="${SUBMISSIONS_PORT:-2465}"
IMAPS_PORT="${IMAPS_PORT:-2993}"
WEB_PORT="${WEB_PORT:-2080}"

if [ -z "${MAIL_ADMIN_PASSWORD:-}" ]; then
    echo "Renode: MAIL_ADMIN_PASSWORD is empty; refusing to start a mail server with no administrator password."
    exit 1
fi

# The administrator login is admin / MAIL_ADMIN_PASSWORD, taken from the
# environment on every start: changing the variable and restarting changes it.
export STALWART_RECOVERY_ADMIN="admin:${MAIL_ADMIN_PASSWORD}"
[ -n "${MAIL_HOSTNAME:-}" ] && export STALWART_HOSTNAME="${MAIL_HOSTNAME}"

# Stalwart 0.16 reads only the data store from the file; everything else is
# in the store and edited from the web admin. Written once, never touched
# again, so a customer who moves to another store keeps their choice.
if [ ! -f "$CONFIG" ]; then
    printf '{"@type":"RocksDb","path":"/home/container/data"}\n' > "$CONFIG"
    echo "Renode: wrote ${CONFIG} (RocksDB in /home/container/data)."
fi

# Listeners live in the store. On a fresh store Stalwart would create its
# defaults on ports 25, 465, 993 and 443, which a Wings container cannot bind,
# so they are created here first, on this server's allocations. Redone only
# when the ports change: the marker holds the ports the store was set up for.
MARKER=/home/container/etc/.renode-listeners
WANT="${SMTP_PORT} ${SUBMISSION_PORT} ${SUBMISSIONS_PORT} ${IMAPS_PORT} ${WEB_PORT}"

jmap() {
    curl -fsS -u "admin:${MAIL_ADMIN_PASSWORD}" -H 'Content-Type: application/json' \
        --data-binary @- "http://127.0.0.1:${WEB_PORT}/jmap/"
}

configure_listeners() {
    echo "Renode: setting up listeners on ${WANT}..."
    STALWART_RECOVERY_MODE=1 STALWART_RECOVERY_MODE_PORT="${WEB_PORT}" \
        "$STALWART" --config "$CONFIG" </dev/null &
    local rpid=$!

    local session=""
    for _ in $(seq 1 60); do
        session=$(curl -fsS -u "admin:${MAIL_ADMIN_PASSWORD}" "http://127.0.0.1:${WEB_PORT}/.well-known/jmap" 2>/dev/null) && break
        kill -0 "$rpid" 2>/dev/null || { echo "Renode: Stalwart exited during setup."; return 1; }
        sleep 1
    done
    local account
    account=$(printf '%s' "$session" | jq -r '(.primaryAccounts["urn:stalwart:jmap"] // (.accounts | keys[0])) // empty')
    if [ -z "$account" ]; then
        echo "Renode: could not open a JMAP session for setup."
        kill -TERM "$rpid" 2>/dev/null; wait "$rpid"
        return 1
    fi

    # Ours are replaced by name; anything the customer added stays.
    local ids
    ids=$(jq -n --arg a "$account" '{using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],
            methodCalls:[["x:NetworkListener/get",{accountId:$a,properties:["id","name"]},"g"],
                         ["x:Tracer/get",{accountId:$a,properties:["id"]},"t"]]}' | jmap)
    local destroy tracers
    destroy=$(printf '%s' "$ids" | jq -c '[.methodResponses[0][1].list[]?
            | select(.name as $n | ["smtp","submission","submissions","imaps","http"] | index($n)) | .id]')
    tracers=$(printf '%s' "$ids" | jq -r '[.methodResponses[1][1].list[]?] | length')

    local request
    request=$(jq -n --arg a "$account" --argjson destroy "${destroy:-[]}" --argjson tracers "${tracers:-0}" \
        --arg smtp "[::]:${SMTP_PORT}" --arg sub "[::]:${SUBMISSION_PORT}" --arg subs "[::]:${SUBMISSIONS_PORT}" \
        --arg imaps "[::]:${IMAPS_PORT}" --arg web "[::]:${WEB_PORT}" '
        def l($name; $proto; $bind; $tls; $implicit):
            {name:$name, protocol:$proto, bind:{($bind):true}, useTls:$tls, tlsImplicit:$implicit};
        {using:["urn:ietf:params:jmap:core","urn:stalwart:jmap"],
         methodCalls:([["x:NetworkListener/set",{accountId:$a, destroy:$destroy, create:{
                 smtp: l("smtp"; "smtp"; $smtp; true; false),
                 submission: l("submission"; "smtp"; $sub; true; false),
                 submissions: l("submissions"; "smtp"; $subs; true; true),
                 imaps: l("imaps"; "imap"; $imaps; true; true),
                 http: l("http"; "http"; $web; false; false)}},"l"]]
             + (if $tracers == 0 then
                 [["x:Tracer/set",{accountId:$a, create:{console:{"@type":"Stdout",
                     enable:true, level:"info", buffered:false, ansi:false, multiline:false}}},"t"]]
               else [] end))}')

    local result ok
    result=$(printf '%s' "$request" | jmap)
    ok=$(printf '%s' "$result" | jq -r '[.methodResponses[]
            | select(.[0] == "error" or ((.[1].notCreated // {}) | length > 0) or ((.[1].notDestroyed // {}) | length > 0))]
            | length')

    kill -TERM "$rpid" 2>/dev/null
    wait "$rpid"

    if [ "$ok" != "0" ]; then
        echo "Renode: listener setup was refused:"
        printf '%s\n' "$result"
        return 1
    fi

    printf '%s\n' "$WANT" > "$MARKER"
    echo "Renode: listeners ready."
}

if [ "$(cat "$MARKER" 2>/dev/null)" != "$WANT" ]; then
    configure_listeners || exit 1
fi

# Pterodactyl startup: {{VAR}} -> ${VAR}. Run as a script, not expanded
# through `eval echo` first: the panel may prefix it with commands of its own
# (a console banner), and `eval echo` would run those inside a command
# substitution and hand their output back as the command to execute.
MODIFIED_STARTUP=$(printf '%s' "${STARTUP:-${STALWART} --config ${CONFIG}}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"

# Own session, so shutdown can signal the whole tree at once.
setsid bash -c "${MODIFIED_STARTUP}" </dev/null &
PID=$!

shutdown() {
    echo "Stopping Stalwart..."
    kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
    wait "$PID"
    exit $?
}
trap shutdown INT TERM

# Stalwart logs each listener separately and in no fixed order, so the panel's
# "started" line is printed here once every port actually answers.
(
    for _ in $(seq 1 120); do
        kill -0 "$PID" 2>/dev/null || exit 0
        all=1
        for p in $WANT; do
            (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null || { all=0; break; }
        done
        if [ "$all" = 1 ]; then
            echo "Renode: Stalwart is ready. Web admin on port ${WEB_PORT} (user admin), SMTP ${SMTP_PORT}, submission ${SUBMISSION_PORT}/${SUBMISSIONS_PORT}, IMAPS ${IMAPS_PORT}."
            exit 0
        fi
        sleep 1
    done
    echo "Renode: not every port answered after two minutes: ${WANT}"
) &

wait "$PID"
exit $?
