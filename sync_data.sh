#!/bin/sh
# 检查环境变量
if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USERNAME" ] || [ -z "$WEBDAV_PASSWORD" ]; then
    echo  "缺少 WEBDAV_URL、WEBDAV_USERNAME 或 WEBDAV_PASSWORD，启动时将不包含备份功能"
    exit 0
fi

# 设置备份路径
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}
FULL_WEBDAV_URL="${WEBDAV_URL}"

if [ -n "$WEBDAV_BACKUP_PATH" ]; then
    FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"
fi

echo "FULL_WEBDAV_URL:${FULL_WEBDAV_URL}"

# 下载最新备份并恢复
restore_backup() {
    echo "开始从 WebDAV 下载最新备份..."
    python3 -c "
import sys
import os
import tarfile
import requests
import shutil
from webdav3.client import Client

options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
client = Client(options)
backups = [file for file in client.list() if file.endswith('.tar.gz') and file.startswith('qinglong_backup_')]
if not backups:
    print('没有找到备份文件')
    sys.exit()
latest_backup = sorted(backups)[-1]
print(f'最新备份文件：{latest_backup}')
with requests.get(f'$FULL_WEBDAV_URL/{latest_backup}', auth=('$WEBDAV_USERNAME', '$WEBDAV_PASSWORD'), stream=True) as r:
    if r.status_code == 200:
        with open(f'/ql/{latest_backup}', 'wb') as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
        print(f'成功下载备份文件到 /ql/{latest_backup}')
        if os.path.exists(f'/ql/{latest_backup}'):
            # 解压备份文件
            with tarfile.open(f'/ql/{latest_backup}', 'r:gz') as tar:
                tar.extractall('/ql/')

                print(f'成功从 {latest_backup} 恢复备份')
        else:
            print('下载的备份文件不存在')
    else:
        print(f'下载备份失败：{r.status_code}')
"
}

# 首次启动时下载最新备份
echo "Downloading latest backup from WebDAV..."
restore_backup

# 同步函数
sync_data() {
    while true; do
        echo "Starting sync process at $(date)"

        if [ -d "/ql/data" ]; then
            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_file="qinglong_backup_${timestamp}.tar.gz"

            # 备份整个data目录
            cd /ql
            tar -czf "/ql/${backup_file}" data

            # 上传新备份到WebDAV
            curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "/ql/${backup_file}" "$FULL_WEBDAV_URL/${backup_file}"
            if [ $? -eq 0 ]; then
                echo "Successfully uploaded ${backup_file} to WebDAV"
            else
                echo "Failed to upload ${backup_file} to WebDAV"
            fi

            # 清理旧备份文件
            python3 -c "
import sys
from webdav3.client import Client
options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
client = Client(options)
backups = [file for file in client.list() if file.endswith('.tar.gz') and file.startswith('qinglong_backup_')]
backups.sort()
if len(backups) > 5:
    to_delete = len(backups) - 5
    for file in backups[:to_delete]:
        client.clean(file)
        print(f'Successfully deleted {file}.')
else:
    print('Only {} backups found, no need to clean.'.format(len(backups)))
" 2>&1

            rm -f "/ql/${backup_file}"
        else
            echo "/ql/data directory does not exist, waiting for next sync..."
        fi

        SYNC_INTERVAL=${SYNC_INTERVAL:-7200}
        echo "Next sync in ${SYNC_INTERVAL} seconds..."
        sleep $SYNC_INTERVAL
    done
}

# 启动同步进程
sync_data