#!/bin/bash

set -euo pipefail

OLD_SERVER="${OLD_SERVER:-}"
NEW_SERVER="${NEW_SERVER:-}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"
WIKI_PATH="${WIKI_PATH:-/var/www/html}"
OLD_WIKI_PATH="${OLD_WIKI_PATH:-$WIKI_PATH}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
RUN_PRECHECK="${RUN_PRECHECK:-0}"
RUN_POSTCHECK="${RUN_POSTCHECK:-0}"
NEW_WIKI_URL="${NEW_WIKI_URL:-}"

usage() {
    cat <<USAGE
Usage: ./migrate.sh --old <old_server> --new <new_server> [options]

Options:
  --old <host>            Old MediaWiki server host/IP
  --new <host>            New MediaWiki server host/IP (default: localhost)
  --wiki-path <path>      Wiki path on new server (default: /var/www/html)
  --old-wiki-path <path>  Wiki path on old server (default: same as --wiki-path)
  --mysql-root-pass <pw>  MySQL root password on new server (optional)
  --non-interactive       Do not prompt; fail if required inputs are missing
  --precheck              Run connectivity and dependency checks before migration
  --postcheck             Run validation checks after migration
  --new-wiki-url <url>    Optional URL used by --postcheck HTTP health check
  -h, --help              Show this help message

You can also provide values with environment variables:
  OLD_SERVER, NEW_SERVER, WIKI_PATH, OLD_WIKI_PATH, MYSQL_ROOT_PASS,
  NON_INTERACTIVE, RUN_PRECHECK, RUN_POSTCHECK, NEW_WIKI_URL
USAGE
}

sql_escape_literal() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\'/\'\'}
    printf "%s" "$value"
}

sql_escape_identifier() {
    local value="$1"
    value=${value//\`/\`\`}
    printf "%s" "$value"
}

shell_escape_single_quotes() {
    printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

run_on_new_server() {
    local cmd="$1"
    if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
        bash -lc "$cmd"
    else
        ssh "$NEW_SERVER" "$cmd"
    fi
}

precheck() {
    echo "Running prechecks..."
    ssh "$OLD_SERVER" "command -v mysql >/dev/null && command -v mysqldump >/dev/null && command -v rsync >/dev/null"
    run_on_new_server "command -v mysql >/dev/null && command -v rsync >/dev/null"
    run_on_new_server "test -d '$WIKI_PATH' && test -w '$WIKI_PATH'"
    if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
        df -h "$WIKI_PATH" >/dev/null
    else
        ssh "$NEW_SERVER" "df -h '$WIKI_PATH' >/dev/null"
    fi
    echo "Prechecks passed."
}

postcheck() {
    echo "Running postchecks..."
    local remote_count
    local local_count
    local escaped_wiki_user
    local escaped_wiki_db
    local escaped_wiki_db_pass
    escaped_wiki_user="$(shell_escape_single_quotes "$WIKI_USER")"
    escaped_wiki_db="$(shell_escape_single_quotes "$WIKI_DB")"
    escaped_wiki_db_pass="$(shell_escape_single_quotes "$WIKI_DB_PASS")"
    remote_count=$(ssh "$OLD_SERVER" "MYSQL_PWD='$escaped_wiki_db_pass' mysql -N -u '$escaped_wiki_user' -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$escaped_wiki_db';\"")

    if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
        local_count=$(MYSQL_PWD="$WIKI_DB_PASS" mysql -N -u "$WIKI_USER" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$WIKI_DB';")
        test -f "$WIKI_PATH/LocalSettings.php"
        test -d "$WIKI_PATH/images"
        test -d "$WIKI_PATH/extensions"
        test -d "$WIKI_PATH/skins"
    else
        local_count=$(ssh "$NEW_SERVER" "MYSQL_PWD='$escaped_wiki_db_pass' mysql -N -u '$escaped_wiki_user' -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$escaped_wiki_db';\"")
        ssh "$NEW_SERVER" "test -f '$WIKI_PATH/LocalSettings.php' && test -d '$WIKI_PATH/images' && test -d '$WIKI_PATH/extensions' && test -d '$WIKI_PATH/skins'"
    fi

    echo "  Old server table count: $remote_count"
    echo "  New server table count: $local_count"
    if [ "$remote_count" != "$local_count" ]; then
        echo "Postcheck failed: table counts differ."
        exit 1
    fi

    if [ -n "$NEW_WIKI_URL" ]; then
        command -v curl >/dev/null
        curl --fail --silent --show-error "$NEW_WIKI_URL" >/dev/null
        echo "  HTTP check OK: $NEW_WIKI_URL"
    fi

    echo "Postchecks passed."
}

require_arg() {
    local option="$1"
    local value="${2:-}"
    if [ -z "$value" ] || [[ "$value" == --* ]]; then
        echo "Missing value for $option"
        usage
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --old)
            require_arg "$1" "${2:-}"
            OLD_SERVER="$2"
            shift 2
            ;;
        --new)
            require_arg "$1" "${2:-}"
            NEW_SERVER="$2"
            shift 2
            ;;
        --wiki-path)
            require_arg "$1" "${2:-}"
            WIKI_PATH="$2"
            shift 2
            ;;
        --old-wiki-path)
            require_arg "$1" "${2:-}"
            OLD_WIKI_PATH="$2"
            shift 2
            ;;
        --mysql-root-pass)
            require_arg "$1" "${2:-}"
            MYSQL_ROOT_PASS="$2"
            shift 2
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --precheck)
            RUN_PRECHECK=1
            shift
            ;;
        --postcheck)
            RUN_POSTCHECK=1
            shift
            ;;
        --new-wiki-url)
            require_arg "$1" "${2:-}"
            NEW_WIKI_URL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$OLD_SERVER" ]; then
    if [ "$NON_INTERACTIVE" = "1" ]; then
        echo "OLD_SERVER is required in --non-interactive mode."
        usage
        exit 1
    fi
    read -rp "Old server (host/IP): " OLD_SERVER
fi
if [ -z "$NEW_SERVER" ]; then
    NEW_SERVER="localhost"
fi

if [ -z "$OLD_SERVER" ] || [ -z "$NEW_SERVER" ]; then
    echo "OLD_SERVER and NEW_SERVER are required."
    usage
    exit 1
fi

cleanup() {
    rm -f /tmp/wiki_db.sql
    ssh "$OLD_SERVER" "rm -f /tmp/wiki_db.sql" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== MediaWiki Migration Script ==="
echo ""
echo "Old server: $OLD_SERVER"
echo "New server: $NEW_SERVER"
echo "Old wiki path: $OLD_WIKI_PATH"
echo "New wiki path: $WIKI_PATH"
echo ""

echo "Checking connectivity..."
ssh "$OLD_SERVER" "echo 'Connected to old server'" >/dev/null
if [ "$NEW_SERVER" != "localhost" ] && [ "$NEW_SERVER" != "127.0.0.1" ]; then
    ssh "$NEW_SERVER" "echo 'Connected to new server'" >/dev/null
fi

if [ "$RUN_PRECHECK" = "1" ]; then
    precheck
fi

echo "Detecting database credentials from old server..."
DB_CONFIG=$(ssh "$OLD_SERVER" "bash -s -- '$OLD_WIKI_PATH'" <<'REMOTE_SCRIPT'
path="$1/LocalSettings.php"
extract() {
    local key="$1"
    awk -v key="$key" '
        $0 ~ ("\\$" key "[[:space:]]*=") {
            if (match($0, /'\''[^'\'']*'\''/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
            if (match($0, /"[^"]*"/)) {
                print substr($0, RSTART + 1, RLENGTH - 2)
                exit
            }
        }
    ' "$path"
}
printf 'WIKI_USER=%s\n' "$(extract wgDBuser)"
printf 'WIKI_DB=%s\n' "$(extract wgDBname)"
printf 'WIKI_DB_PASS=%s\n' "$(extract wgDBpassword)"
REMOTE_SCRIPT
)

while IFS='=' read -r key value; do
    case "$key" in
        WIKI_USER) WIKI_USER="$value" ;;
        WIKI_DB) WIKI_DB="$value" ;;
        WIKI_DB_PASS) WIKI_DB_PASS="$value" ;;
    esac
done <<< "$DB_CONFIG"

echo "  Database: $WIKI_DB"
echo "  User: $WIKI_USER"
echo ""

if [ -z "${WIKI_USER:-}" ] || [ -z "${WIKI_DB:-}" ]; then
    echo "Failed to detect database settings from LocalSettings.php"
    exit 1
fi

echo "Step 1: Backing up database on old server..."
ESCAPED_WIKI_USER="$(shell_escape_single_quotes "$WIKI_USER")"
ESCAPED_WIKI_DB="$(shell_escape_single_quotes "$WIKI_DB")"
ESCAPED_WIKI_DB_PASS="$(shell_escape_single_quotes "$WIKI_DB_PASS")"
ssh "$OLD_SERVER" "MYSQL_PWD='$ESCAPED_WIKI_DB_PASS' mysqldump -u '$ESCAPED_WIKI_USER' '$ESCAPED_WIKI_DB' > /tmp/wiki_db.sql"

echo "Step 2: Copying database dump to new server..."
if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
    scp "$OLD_SERVER":/tmp/wiki_db.sql /tmp/wiki_db.sql
else
    ssh "$OLD_SERVER" "scp /tmp/wiki_db.sql '$NEW_SERVER':/tmp/wiki_db.sql"
fi

echo "Step 3: Copying wiki files (images, uploads, extensions, skins)..."
if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
    rsync -az --progress "$OLD_SERVER":"$OLD_WIKI_PATH"/images/ "$WIKI_PATH"/images/
    rsync -az --progress "$OLD_SERVER":"$OLD_WIKI_PATH"/extensions/ "$WIKI_PATH"/extensions/
    rsync -az --progress "$OLD_SERVER":"$OLD_WIKI_PATH"/skins/ "$WIKI_PATH"/skins/
else
    ssh "$NEW_SERVER" "mkdir -p '$WIKI_PATH/images' '$WIKI_PATH/extensions' '$WIKI_PATH/skins'"
    ssh "$OLD_SERVER" "rsync -az --progress '$OLD_WIKI_PATH'/images/ '$NEW_SERVER':'$WIKI_PATH'/images/"
    ssh "$OLD_SERVER" "rsync -az --progress '$OLD_WIKI_PATH'/extensions/ '$NEW_SERVER':'$WIKI_PATH'/extensions/"
    ssh "$OLD_SERVER" "rsync -az --progress '$OLD_WIKI_PATH'/skins/ '$NEW_SERVER':'$WIKI_PATH'/skins/"
fi

echo "Step 4: Copying LocalSettings.php..."
if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
    scp "$OLD_SERVER":"$OLD_WIKI_PATH"/LocalSettings.php "$WIKI_PATH"/
else
    ssh "$OLD_SERVER" "scp '$OLD_WIKI_PATH'/LocalSettings.php '$NEW_SERVER':'$WIKI_PATH'/LocalSettings.php"
fi

echo "Step 5: Creating database and user on new server..."
if [ -z "$MYSQL_ROOT_PASS" ]; then
    echo "No MYSQL_ROOT_PASS provided. Trying MySQL socket/root authentication on new server."
fi

WIKI_DB_SQL_ID="$(sql_escape_identifier "$WIKI_DB")"
WIKI_USER_SQL="$(sql_escape_literal "$WIKI_USER")"
WIKI_DB_PASS_SQL="$(sql_escape_literal "$WIKI_DB_PASS")"
MYSQL_CREATE_CMD="CREATE DATABASE IF NOT EXISTS \`$WIKI_DB_SQL_ID\`; CREATE USER IF NOT EXISTS '$WIKI_USER_SQL'@'localhost' IDENTIFIED BY '$WIKI_DB_PASS_SQL'; GRANT ALL PRIVILEGES ON \`$WIKI_DB_SQL_ID\`.* TO '$WIKI_USER_SQL'@'localhost'; FLUSH PRIVILEGES;"

if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
    if [ -n "$MYSQL_ROOT_PASS" ]; then
        mysql -u root -p"$MYSQL_ROOT_PASS" -e "$MYSQL_CREATE_CMD"
    else
        mysql -u root -e "$MYSQL_CREATE_CMD"
    fi
else
    if [ -n "$MYSQL_ROOT_PASS" ]; then
        ssh "$NEW_SERVER" "mysql -u root -p'$MYSQL_ROOT_PASS' -e \"$MYSQL_CREATE_CMD\""
    else
        ssh "$NEW_SERVER" "mysql -u root -e \"$MYSQL_CREATE_CMD\""
    fi
fi

echo "Step 6: Importing database..."
if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
    MYSQL_PWD="$WIKI_DB_PASS" mysql -u "$WIKI_USER" "$WIKI_DB" < /tmp/wiki_db.sql
else
    ssh "$NEW_SERVER" "MYSQL_PWD='$ESCAPED_WIKI_DB_PASS' mysql -u '$ESCAPED_WIKI_USER' '$ESCAPED_WIKI_DB' < /tmp/wiki_db.sql"
fi

echo "Step 7: Setting permissions on new server..."
if [ "$NEW_SERVER" = "localhost" ] || [ "$NEW_SERVER" = "127.0.0.1" ]; then
    chown -R www-data:www-data "$WIKI_PATH"/images/
    chown -R www-data:www-data "$WIKI_PATH"/extensions/
    chown -R www-data:www-data "$WIKI_PATH"/skins/
    chown www-data:www-data "$WIKI_PATH"/LocalSettings.php
else
    ssh "$NEW_SERVER" "chown -R www-data:www-data '$WIKI_PATH'/images/ '$WIKI_PATH'/extensions/ '$WIKI_PATH'/skins/ && chown www-data:www-data '$WIKI_PATH'/LocalSettings.php"
fi

echo ""
echo "=== Migration Complete ==="
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "1. Validate wiki access in browser"
echo "2. Update DNS/point old server IP to new server"
echo "3. Run update.php if needed: php maintenance/update.php"
echo "4. Clear caches: rm -rf $WIKI_PATH/cache/*"

if [ "$RUN_POSTCHECK" = "1" ]; then
    postcheck
fi
