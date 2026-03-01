# MediaWiki Migration Checklist

## Pre-Migration: New Debian Server Setup

### Reliability improvements in this repo
The migration script now includes:
- Strict argument value validation for all flags that expect values.
- Safer database setting extraction from `LocalSettings.php` supporting both single and double quoted values.
- Automatic cleanup of `/tmp/wiki_db.sql` on exit (local + old server).


### 1. Install required packages
```bash
apt update
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-mbstring rsync
```

### 2. Configure MariaDB
```bash
mysql_secure_installation
```

### 3. Install the same MediaWiki version on the new server
Check old server version:
```bash
ssh old-server "grep -E 'wgVersion|MW_VERSION' /var/www/html/LocalSettings.php"
```

Then install the same version on the new server.

### 4. Run migration (no script editing required)
```bash
chmod +x migrate.sh
./migrate.sh --old old-server --new localhost
```

Optional flags:
```bash
./migrate.sh --old old-server --new new-server --wiki-path /var/www/html --old-wiki-path /var/www/html
```

Validation flags (recommended):
```bash
./migrate.sh --old old-server --new localhost --precheck --postcheck --new-wiki-url http://localhost
```

You can also set environment variables instead of flags:
```bash
OLD_SERVER=old-server NEW_SERVER=localhost ./migrate.sh
```

For fully unattended runs (no prompts), use non-interactive mode:
```bash
OLD_SERVER=old-server NEW_SERVER=localhost NON_INTERACTIVE=1 ./migrate.sh --non-interactive
```

You can also enable checks through environment variables:
```bash
OLD_SERVER=old-server NEW_SERVER=localhost RUN_PRECHECK=1 RUN_POSTCHECK=1 NEW_WIKI_URL=http://localhost ./migrate.sh
```

If `MYSQL_ROOT_PASS` is not set, the script now automatically attempts MySQL root socket authentication.

### 5. What the script now automates
- Detects `wgDBuser`, `wgDBname`, and `wgDBpassword` from old `LocalSettings.php`
- Dumps DB from old server and transfers it
- Copies `images`, `extensions`, `skins`, and `LocalSettings.php`
- Creates DB/user/grants on new server
- Imports the DB
- Sets ownership for migrated files

### 6. Post-migration checks
- Test wiki loads
- Upload test image
- Check `Special:Version` matches old server
- Update DNS A record to new server IP

You can partially automate post-migration verification with `--postcheck`, which validates copied file paths and compares old/new table counts.
