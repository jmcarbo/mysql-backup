#!/bin/bash

if [ "${MYSQL_ENV_MYSQL_PASS}" == "**Random**" ]; then
        unset MYSQL_ENV_MYSQL_PASS
fi

MYSQL_HOST=${MYSQL_PORT_3306_TCP_ADDR:-${MYSQL_HOST}}
MYSQL_HOST=${MYSQL_PORT_1_3306_TCP_ADDR:-${MYSQL_HOST}}
MYSQL_PORT=${MYSQL_PORT_3306_TCP_PORT:-${MYSQL_PORT}}
MYSQL_PORT=${MYSQL_PORT_1_3306_TCP_PORT:-${MYSQL_PORT}}
MYSQL_USER=${MYSQL_USER:-${MYSQL_ENV_MYSQL_USER}}
MYSQL_PASS=${MYSQL_PASS:-${MYSQL_ENV_MYSQL_PASS}}

[ -z "${MYSQL_HOST}" ] && { echo "=> MYSQL_HOST cannot be empty" && exit 1; }
[ -z "${MYSQL_PORT}" ] && { echo "=> MYSQL_PORT cannot be empty" && exit 1; }
[ -z "${MYSQL_USER}" ] && { echo "=> MYSQL_USER cannot be empty" && exit 1; }
[ -z "${MYSQL_PASS}" ] && { echo "=> MYSQL_PASS cannot be empty" && exit 1; }

BACKUP_CMD="mysqldump -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER} -p${MYSQL_PASS} ${EXTRA_OPTS} ${MYSQL_DB} > /backup/"'${BACKUP_NAME}'

echo "=> Creating backup script"
rm -f /backup.sh
cat <<EOF >> /backup.sh
#!/bin/bash
MAX_BACKUPS=${MAX_BACKUPS}

BACKUP_NAME=\$(date +\%Y.\%m.\%d.\%H\%M\%S).sql

echo "=> Backup started: \${BACKUP_NAME}"
if ${BACKUP_CMD} ;then
    echo "   Backup succeeded"
else
    echo "   Backup failed"
    rm -rf /backup/\${BACKUP_NAME}
fi

if [ -n "\${MAX_BACKUPS}" ]; then
    while [ \$(ls /backup -N1 | wc -l) -gt \${MAX_BACKUPS} ];
    do
        BACKUP_TO_BE_DELETED=\$(ls /backup -N1 | sort | head -n 1)
        echo "   Backup \${BACKUP_TO_BE_DELETED} is deleted"
        rm -rf /backup/\${BACKUP_TO_BE_DELETED}
    done
fi
echo "=> Backup done"
EOF
chmod +x /backup.sh

echo "=> Creating restore script"
rm -f /restore.sh
cat <<EOF >> /restore.sh
#!/bin/bash
echo "=> Restore database from \$1"
if mysql -h${MYSQL_HOST} -P${MYSQL_PORT} -u${MYSQL_USER} -p${MYSQL_PASS} < \$1 ;then
    echo "   Restore succeeded"
else
    echo "   Restore failed"
fi
echo "=> Done"
EOF
chmod +x /restore.sh

touch /mysql_backup.log
tail -F /mysql_backup.log &

if [ -n "${INIT_BACKUP}" ]; then
    echo "=> Create a backup on the startup"
    /backup.sh
elif [ -n "${INIT_RESTORE_LATEST}" ]; then
    echo "=> Restore lates backup"
    until nc -z $MYSQL_HOST $MYSQL_PORT
    do
        echo "waiting database container..."
        sleep 1
    done
    ls -d -1 /backup/* | tail -1 | xargs /restore.sh
elif [ -n "${INIT_RESTORE_URL}" ]; then
	MINIO_HOST=${MINIO_HOST:-myminio}
	[ -z "${MINIO_HOST_URL}" ] && { echo "=> MINIO_HOST_URL cannot be empty" && exit 1; }
	[ -z "${MINIO_ACCESS_KEY}" ] && { echo "=> MINIO_ACCESS_KEY cannot be empty" && exit 1; }
	[ -z "${MINIO_SECRET_KEY}" ] && { echo "=> MINIO_SECRET_KEY cannot be empty" && exit 1; }

	mkdir -p "$HOME/.mc"
cat <<EOF >"$HOME/.mc/config.json"
{
	"version": "7",
	"hosts": {
	"${MINIO_HOST}": {
	"url": "${MINIO_HOST_URL}",
	"accessKey": "${MINIO_ACCESS_KEY}",
	"secretKey": "${MINIO_SECRET_KEY}",
	"api": "S3v4"
	}
	}
}
EOF
	mc cp "${INIT_RESTORE_URL}" /backup/restore_target.sql 	
    	until nc -z $MYSQL_HOST $MYSQL_PORT
    	do
        	echo "waiting database container..."
        	sleep 1
    	done
	/restore.sh /backup/restore_target.sql
fi

echo "${CRON_TIME} /backup.sh >> /mysql_backup.log 2>&1" > /crontab.conf
crontab  /crontab.conf
echo "=> Running cron job"
exec cron -f
