#!/bin/bash
# Author:AbbasA
# Usage
#./postbackup.sh database_name 'exclude-table=<table_name>'
# For excluding multiple tables
#./postbackup.sh database_name '--exclude-table=<table1> --exclude-table=<table2>' <ip-db-server>
#In this mode, the script will exit if we try to use an uninitialised variable. Useful for preventing rm -rf uninitialized_variable/ type disasters
set -u

#set -o pipefail causes a pipeline to produce a failure return code if any command results in an error. Normally, pipelines only return a failure if the last command errors.
set -o pipefail

# Credentials will be sourced from another file
source /root/creds.sh

#Comma separated list of mail addresses
maillist=""
number_of_days=3
key="/opt/keys/backup_key.pem.pub"
upload_flag=0
username="postgres"
port=
args=("$@")
database_name="${args[0]}"
excluded_tables="${args[1]:-}"
dbserver="${args[2]}"
container="$database_name"
function checkStatusOfLastCommand
{
	if [ "$1" -ne 0 ]
	then
	  echo "$2" | mutt -s "Postgres Backup Alert (FAILED)" -- $maillist
        exit
	fi
}

if [ -z ${database_name} ]
then
 echo "The correct Syntax for the script is ./postbackup.sh <dbname> '<tables to be excluded in pg_dump syntax>' <ip-db-server>"
 echo " ./postgres_backup.sh test '-T messages -T commands' <ip-db-servers>"
 exit 1
fi

# String to append to the name of the backup files
timestamp=`date +%Y-%m-%d-%H-%M`

# Local location to place backups.
backup_dir="/opt/backups/${database_name}/"

mkdir -p $backup_dir/$timestamp
checkStatusOfLastCommand $? "Failed creating directory! May be there is an issue with space or system has run out of inodes"

backup_dir_final="$backup_dir/$timestamp/"

#Dumping Database
echo "Dumping ${database_name} to ${backup_dir_final}${database_name}_${timestamp}.sql"
## Trickle is a utility which controls the bandwidth utilization for a process. switch '-s' means it is running in standalone mode with upload and download speed '-u,-d' in KB/s.
trickle -s -u 10000 -d 10000 ssh $username@$dbserver -p$port "/usr/bin/nice -n 10 /usr/bin/ionice -c2 -n7 pg_dump ${database_name} ${excluded_tables}" > ${backup_dir_final}${database_name}_${timestamp}.sql
checkStatusOfLastCommand $? "Pg DUMP Failed for ${database_name}"

#Compress the backup file
echo "Compressing the backup"
gzip ${backup_dir_final}${database_name}_${timestamp}.sql
checkStatusOfLastCommand $? "Failed compressing the database! Please check"

## Encryption
echo "Encrypting the file"
ccrypt ${backup_dir_final}${database_name}_${timestamp}.sql.gz -k $key

## Changing directory to the backup directory
cd $backup_dir_final

# Splitting the file
filesize=`ls -l --block-size=K ${backup_dir_final}${database_name}_${timestamp}.sql.gz.cpt | awk {'print $5'} | tr -d "K"`
checkStatusOfLastCommand $? "Unable to get the size of file!"
filesize_gb=`echo $((filesize/1048576))`

if [ ${filesize_gb} -gt 1 ] || [ ${filesize_gb} == 1 ]
  then
	echo "Splitting file"
	split -b 1G -d ${backup_dir_final}${database_name}_${timestamp}.sql.gz.cpt backup
	checkStatusOfLastCommand $? "Failed Splitting the files! Please check!"
	upload_flag=1
else
	echo "Uploading directly since file size is smaller"
	cd $backup_dir
	swift -A $HOST -U $USER -K $PASSWD upload --object-threads 2 --skip-identical -c $container $timestamp/${database_name}_${timestamp}.sql.gz.cpt
        if [ $? -ne 0 ]
                then
                        echo "Retrying uploading the directory!"
                        swift -A $HOST -U $USER -K $PASSWD upload --object-threads 2 --skip-identical -c $container $timestamp/${database_name}_${timestamp}.sql.gz.cpt
        fi
	checkStatusOfLastCommand $? "Upload to Object Storage Failed! Please check!"

fi

## Cleaning the directory for upload on Object Storage
echo "Moving original encrypted tar files"
mv ${backup_dir_final}${database_name}_${timestamp}.sql.gz.cpt ${backup_dir}

#Change to backup directory
cd $backup_dir

#Uploading the file in object storage
if [ $upload_flag == 1 ]
then
	echo "Uploading files in Object Storage"
	swift -A $HOST -U $USER -K $PASSWD upload --object-threads 2 --skip-identical -c $container $timestamp/
	if [ $? -ne 0 ]
		then
			echo "Retrying uploading the directory!"
    			swift -A $HOST -U $USER -K $PASSWD upload --object-threads 2 --skip-identical -c $container $timestamp/
	fi
	checkStatusOfLastCommand $? "Upload to Object Storage Failed! Please check!"
fi

#To check if the string is empty.
if [ -n "$timestamp" ]
then
	echo "Cleaning files after upload"
	rm -rf $timestamp/
	checkStatusOfLastCommand $? "Failed removing the directory!"
fi
##Cleaning backups older than 3 days.
if [ "$PWD" = "${backup_dir}" ]
then
	echo "Cleaning backups older than ${number_of_days} on local machine"
	find ${backup_dir} -type f -prune -mtime +${number_of_days} -exec rm -f {} \;
fi
