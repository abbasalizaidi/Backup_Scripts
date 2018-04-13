#!/bin/bash
# This bash script delete backups CDN and subdomain filesystem that are older 12 days from the ObjectStore using the Swift CLI Client

#In this mode, the script will exit if we try to use an uninitialised variable. Useful for preventing rm -rf uninitialized_variable/ type disasters
set -u

#set -o pipefail causes a pipeline to produce a failure return code if any command results in an error. Normally, pipelines only return a failure if the last command errors.
set -o pipefail

#In this mode, any command our script runs which returns a non-zero exitcode - will cause your script to itself terminate immediately with an error. Basically script won't continue if an error occurs
set -e

mail_id=abbasalizaidi1990@gmail.com
if [ "$#" != 2 ]
  then
    echo "2 args needed, 1:- No. of days to kept in backup, 2:- container name"
  exit 0
fi

function checkStatusOfLastCommand {
    if [ "$1" -ne 0 ]
    then
        mail -s "$4 Periodic Backup Delete Failed at $2" ${mail_id} <<< "$3"
        exit
    fi
}

# Credentials will be sourced from another file
source /root/creds.sh

CONTAINER="$2"
TIMESTAMP=$(date +%Y-%m-%d)
TIMESTAMP_OFFSET=$(date  --date="$1 days ago" +%Y-%m-%d)
OBJECTS_TO_BE_DELETED=""
OBJECTS_FAILED_TO_BE_DELETED=""

OUTPUT="$(swift -A $HOST -U $USER -K $PASSWD list $CONTAINER)"
checkStatusOfLastCommand $? $TIMESTAMP "SWIFT_GET_LIST_FAILED" $CONTAINER

read -r -a containerContents <<<$OUTPUT
checkStatusOfLastCommand $? $TIMESTAMP "READ_COMMAND_SWIFT_LIST_FAILED" $CONTAINER

for object in ${containerContents[*]}

do
	IFS=-
	set -f
	objectArr=($object)
	objectDate="${objectArr[0]}-${objectArr[1]}-${objectArr[2]}"

	IFS=
	objectDate=`date --date="${objectDate}" +%Y-%m-%d`

	if [[ $TIMESTAMP_OFFSET > $objectDate ]] ; then
          OBJECTS_TO_BE_DELETED="${OBJECTS_TO_BE_DELETED} \"${object}\""
	fi
done

#To check if the string is empty.This is critical since an empty string will delete all the backup
if [ -n "$OBJECTS_TO_BE_DELETED" ] ;
	then
	IFS=' '
	for i in `echo $OBJECTS_TO_BE_DELETED | tr -d '"'`
	do
           swift -A $HOST -U $USER -K $PASSWD delete $CONTAINER "$i"
	   failed=$?
	   if [ $failed -ne 0 ]
		then
		OBJECTS_FAILED_TO_BE_DELETED="${OBJECTS_FAILED_TO_BE_DELETED} \"${i}\""
	   fi
	done
        # In case of network glitches, script will retry deleting files which failed.
        if [ -n $OBJECTS_FAILED_TO_BE_DELETED ]
                then
		IFS=' '
		for i in `echo $OBJECTS_FAILED_TO_BE_DELETED | tr -d '"'`
        	do
           	   swift -A $HOST -U $USER -K $PASSWD delete $CONTAINER "$i"
		       checkStatusOfLastCommand $? $TIMESTAMP "SWIFT_DELETE_OBJECTS_FAILED" $CONTAINER
        	done
        fi
fi
