# MediaWiki Migration Checklist

## Pre-Migration: New Debian Server Setup

### 1. Install required packages
```bash
apt update
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-mbstring
```

### 2. Configure MariaDB
```bash
mysql_secure_installation
```

### 3. Create database user (matching old server)
```bash
mysql -u root -p
CREATE USER 'wikiuser'@'localhost' IDENTIFIED BY 'your_password';
GRANT ALL PRIVILEGES ON wikidb.* TO 'wikiuser'@'localhost';
FLUSH PRIVILEGES;
exit
```

### 4. Install MediaWiki same version as old server
Check old server version:
```bash
ssh old-server "cat /var/www/html/LocalSettings.php | grep wgVersion"
```

Download and install same version on new server.

### 5. Edit migrate.sh with your server IPs
```bash
nano migrate.sh
# Set OLD_SERVER and NEW_SERVER
```

### 6. Run migration
```bash
chmod +x migrate.sh
./migrate.sh
```

### 7. Post-migration checks
- Test wiki loads
- Upload test image
- Check Special:Version matches old server
- Update DNS A record to point to new server IP
