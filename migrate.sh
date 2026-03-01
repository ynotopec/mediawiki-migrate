#!/bin/bash

set -e

OLD_SERVER=""
NEW_SERVER=""
MYSQL_ROOT_PASS=""  # Set root password if needed to create db/user on new server
WIKI_PATH="/var/www/html"

echo "=== MediaWiki Migration Script ==="
echo ""

echo "Detecting database credentials from old server..."
WIKI_USER=$(ssh $OLD_SERVER "grep wgDBuser /var/www/html/LocalSettings.php | cut -d'\"' -f2")
WIKI_DB=$(ssh $OLD_SERVER "grep wgDBname /var/www/html/LocalSettings.php | cut -d'\"' -f2")
WIKI_DB_PASS=$(ssh $OLD_SERVER "grep wgDBpassword /var/www/html/LocalSettings.php | cut -d'\"' -f2")

echo "  Database: $WIKI_DB"
echo "  User: $WIKI_USER"
echo ""

if [ -z "$OLD_SERVER" ] || [ -z "$NEW_SERVER" ]; then
    echo "Please edit this script and set:"
    echo "  OLD_SERVER - IP or hostname of old Ubuntu system"
    echo "  NEW_SERVER - IP or hostname of new Debian system"
    exit 1
fi

echo "Step 1: Backing up database on old server..."
ssh $OLD_SERVER "mysqldump -u $WIKI_USER -p $WIKI_DB > /tmp/wiki_db.sql"

echo "Step 2: Copying database dump to new server..."
scp $OLD_SERVER:/tmp/wiki_db.sql /tmp/

echo "Step 3: Copying wiki files (images, uploads, extensions, skins)..."
rsync -avz --progress $OLD_SERVER:$WIKI_PATH/images/ $WIKI_PATH/images/
rsync -avz --progress $OLD_SERVER:$WIKI_PATH/extensions/ $WIKI_PATH/extensions/
rsync -avz --progress $OLD_SERVER:$WIKI_PATH/skins/ $WIKI_PATH/skins/

echo "Step 4: Copying LocalSettings.php..."
scp $OLD_SERVER:$WIKI_PATH/LocalSettings.php $WIKI_PATH/

echo "Step 5: Creating database and user on new server..."
if [ -n "$MYSQL_ROOT_PASS" ]; then
    mysql -u root -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS $WIKI_DB; CREATE USER IF NOT EXISTS '$WIKI_USER'@'localhost' IDENTIFIED BY '$WIKI_DB_PASS'; GRANT ALL PRIVILEGES ON $WIKI_DB.* TO '$WIKI_USER'@'localhost'; FLUSH PRIVILEGES;"
else
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS $WIKI_DB; CREATE USER IF NOT EXISTS '$WIKI_USER'@'localhost' IDENTIFIED BY '$WIKI_DB_PASS'; GRANT ALL PRIVILEGES ON $WIKI_DB.* TO '$WIKI_USER'@'localhost'; FLUSH PRIVILEGES;"
fi

echo "Step 6: Importing database..."
mysql -u $WIKI_USER -p"$WIKI_DB_PASS" $WIKI_DB < /tmp/wiki_db.sql

echo "Step 7: Setting permissions on new server..."
chown -R www-data:www-data $WIKI_PATH/images/
chown -R www-data:www-data $WIKI_PATH/extensions/
chown -R www-data:www-data $WIKI_PATH/skins/
chown www-data:www-data $WIKI_PATH/LocalSettings.php

echo ""
echo "=== Migration Complete ==="
echo ""
echo "IMPORTANT NEXT STEPS:"
echo "1. Update DNS/point old server IP to new server"
echo "2. Install Apache/Nginx, PHP, and MariaDB on new Debian if not done"
echo "3. Test wiki access in browser"
echo "4. Run update.php if needed: php maintenance/update.php"
echo "5. Clear caches: rm -rf $WIKI_PATH/cache/*"
