#!/bin/bash
#
# 	To check a download is valid
# cd /home/silent/public_html/multimedia; ctorrent -c name_or_file.torrent
#
#
# (MediaPort) smdownload.sh -download SERVERIP SERVERFILE LOCALFILE_WITH_PATH REDIRECT_STDOUT REDIRECT_STDERR filesize
# (FirePanel) smdownload.sh -voice_evac_download SERVERIP SERVERFILE LOCALFILE_WITH_PATH 
# (server)    smdownload.sh [option] 
#
# By: Chris Rider - 4Q, 2009
#
#    Syntax:  smdownload.sh -option serverIP serverFile [localFileWithPath]
#	option:		   This is what you want this script to do (see available options below)
#			    -torrent_create_meta	Launch the script to create the torrent metainfo file (.torrent)
#			    -torrent_seed		Launch the script to run a ctorrent client on the server to seed the file
#			    -torrent_get_meta		Download the torrent metainfo file (.torrent) from the server
#			    -torrent_leech		Launch the script to run a ctorrent client instance on the sign to leech the file
#			    -download			Launch the script to direct-download the file by default
#	serverIP	   This is the IP address of the server
#	serverFile	   This is the filename (including any applicable extensions) IMPORTANT!! This is NOT the .torrent metainfo file!
#	localFileWithPath  This is the destination, including the full local path. (only required for -download option... doesn't apply for other options)	
#
#    Examples:
#	1) Make the server seed a file to the torrent cloud:		smdownload.sh -torrent_seed 192.168.1.16 newsVideo.mpg 0
#	2) Initiate a torrent download on a mediaport:			smdownload.sh -torrent_leech 192.168.1.16 newsVideo.mpg 0		*Note... must do server side stuff first, and get the meta file first, of course
#	3) Create a .torrent metainfo file on the server:		smdownload.sh -torrent_create_meta 192.168.1.16 newsVideo.mpg 0
#	4) Get the .torrent metainfo file from the server:		smdownload.sh -torrent_get_meta 192.168.1.16 newsVideo.mpg 0
#	5) Directly download a file from the server:			smdownload.sh -download 192.168.1.16 newsVideo.mpg /home/silentm/public_html/multimedia/newsVideo.mpg 88345
#
#
SILENTM_HOME=`cat /etc/silentm/home`
DESIRED_OPTION="$1"
SERVER_IP="$2"
FILE_NAME="$3"
LOCAL_NAME="$4"
REDIRECT_STDOUT="$5"
REDIRECT_STDERR="$6"
FILE_SIZE="$7"
LOG_FILE="/home/silentm/log/torrent.log"
PID=$$
DATE=`date`
DATE_SECONDS=`date +%s`
SCRIPT_PID_DATE="$PID.$DATE_SECONDS" 

# DEFINE THINGS ################
FILE_PATH="$SILENTM_HOME/public_html/multimedia"
SEEDER_SEED_HOURS=3		# Enter 0 for inifinite (not recommended because the process that will be created will never end)
SEEDER_EXIT_RATIO=3.5	# Enter 0 to disable (recommend to specify seed hours above if entering 0 here, otherwise process will never end)
SEEDER_MAX_PEERS=2		# Enter 0 to default to 100 (not recommended more than 2 or 3 - tests imply no gains in doing so, and it increases chance that cloud will not receive entire file)
LEECHER_MIN_PEERS=8		# Using this as a patch to help force tracker updates more frequently - hopefully to prevent zombie ctorrent sessions (those that have lost tracker connection for longer than the cloud takes to distribute the file)
LEECHER_SEED_HOURS=1	# Enter 0 for infinite (not recommended)
BANDWIDTH_PERCENT=.90	# The maximum full portion of the pipe to use (full duplex), as a decimal-representative percentage... Ex. 90% = .90 --NOTE: half-duplex will automatically be calculated from this!
################################

# DETERMINE THE NIC'S SPEED SO WE CAN CALCULATE OPTIMAL BANDWIDTH LIMITS
NIC_SPEED=`/sbin/ethtool eth0 | grep Speed | cut -d ' ' -f 2 | cut -d 'M' -f 1`
BANDWIDTH_PERCENT_HALF=$(echo "scale=2; $BANDWIDTH_PERCENT/2" | bc -l)

# DOWNLOADS THE .TORRENT METAINFO HASH FILE FROM THE SERVER (needed in order to start a torrent transfer)
GetMetaFile()
	{
	if [ ! -e "$LOCAL_NAME.torrent" ]
	then
		/usr/bin/curl "http://$SERVER_IP/~silentm/multimedia/$FILE_NAME.torrent" -o "$LOCAL_NAME.torrent"

		result=`grep "404 Not Found" "$LOCAL_NAME.torrent" `
		if [ "$result" != "" ]
		then
			# File was not present
			rm "$LOCAL_NAME.torrent"
		fi
	fi
	}

# Creates the .torrent metainfo hash file
CreateTorrentMetaFile()
	{
	if [ -e /usr/local/bin/ctorrent ]
	then
		if [ ! -e "$FILE_NAME.torrent" ]
		then
			# -t	Creates torrent metainfo file
			# -u	Specifies the tracker's announce URL
			# -s	Path to save to and name to give to the torrent metainfo file that will be created
			/usr/local/bin/ctorrent -t -u"http://$SERVER_IP:6969/announce" -s"$FILE_NAME.torrent" "$FILE_NAME"
		fi

		# indicate we are done create meta file
		echo 1 > /tmp/torrent_create_meta
	else
		echo "ctorrent is not installed!"
	fi
	}

# VERIFIES WHETHER THE FILE IS COMPLETE (ACCORDING TO ITS METAFILE)
# Once this function has been called, check the result by reading the value of $TORRENT_COMPLETED_CHECK_OK
CheckTorrentedFile()
	{
	# -c	Check pieces of the file
	TORRENT_PERCENT_CHECKED_COMPLETED=$(/usr/local/bin/ctorrent -c "$FILE_NAME.torrent" | grep "Already/Total:" | cut -d '(' -f 2 | cut -d '%' -f 1)
	if [[ $TORRENT_PERCENT_CHECKED_COMPLETED -eq 100 ]]; then
		# the file did complete, so set the return value (global variable for script simplicity)
		TORRENT_COMPLETED_CHECK_OK="true"
	else
		# the file didn't complete or we were unable to determine, so fall-back and indicate that we should try to curl the file instead
		TORRENT_COMPLETED_CHECK_OK="false"
	fi
	}

# STARTS THE TORRENT CLIENT ON THE SERVER
StartSeederClientInstance()
	{
	bandwidthAllocation=`echo "($NIC_SPEED * $BANDWIDTH_PERCENT ) * 122 / 1" | bc`
	# Path and name of the torrent metainfo file
	# -s	Path to and name of the torrent source file that will be "uploaded" (seeded)
	# -f	Force seed mode (skips hash checking, which is unnecessary if we're sure we have the complete file)
	# -U	Upload limit in KB/s (ctorrent uses this, specifically, to intelligently manage the overall torrent speed)
	# -e	Number of hours, which once reached, will close this process (timer begins almost immediately in this case)
	# -E	Ratio, which once reached, will trigger the closing of this process. (Should be higher than -M paramater, below)
	# -M	Maximum number of peers to connect to, for seeding
	# -d	Fork to background and run as a daemon
	/usr/local/bin/ctorrent "$FILE_NAME.torrent" -s"$FILE_NAME" -f -U$bandwidthAllocation -e$SEEDER_SEED_HOURS -E$SEEDER_EXIT_RATIO -M$SEEDER_MAX_PEERS -d
	}

# STARTS THE TORRENT CLIENT ON THE MEDIAPORT
StartLeecherClientInstance()
	{
	#echo "Determining bandwidth allocation for $NIC_SPEED Mb/s connection"
	bandwidthAllocation=`echo "($NIC_SPEED * $BANDWIDTH_PERCENT ) * 122 / 1" | bc`
	bandwidthAllocationHalf=`echo "($NIC_SPEED * $BANDWIDTH_PERCENT_HALF ) * 122 / 1" | bc`
	#echo "Starting ctorrent client for leeching:"
	#echo "  -Torrent meta file....  $FILE_NAME.torrent"
	#echo "  -File to save.........  $FILE_PATH/$FILE_NAME"
	#echo "  -Bandwidth (half).....  $bandwidthAllocationHalf KB/s (`echo "$BANDWIDTH_PERCENT_HALF*100/1" | bc`% of pipe)"
	#echo "  -Bandwidth (full).....  $bandwidthAllocation KB/s (`echo "$BANDWIDTH_PERCENT*100/1" | bc`% of pipe)"
	#echo "  -Exit time............  $LEECHER_SEED_HOURS hour(s)  ("`date -d"$LEECHER_SEED_HOURS hours" +"%D %r"`")"
	#echo ""
	# Path and name of the torrent metainfo file
	# -s	Path to save to and name to give to the file that will be "downloaded" (leeched)
	# -a 	Pre-allocates the file on the hard drive
	# -U	Upload limit in KB/s (ctorrent uses this, specifically, to intelligently manage the overall torrent speed)
	# -e	Number of hours to exit (close) the ctorrent instance (timer begins once seeding has begun)
	# -d	Fork to background and run as a daemon
	# -m	Minimum number of peers to connect to (the higher, the more likely ctorrent will update tracker stats - hopefully to keep the connection alive better and prevent zombie processes / incomplete files)
	if [ -e "$LOCAL_NAME.torrent" ]
	then
		echo "Executing:  /usr/local/bin/ctorrent \"$LOCAL_NAME.torrent\" -s\"$LOCAL_NAME.$SCRIPT_PID_DATE.part\" -U$bandwidthAllocation -e$LEECHER_SEED_HOURS -m$LEECHER_MIN_PEERS" >> $LOG_FILE
		/usr/local/bin/ctorrent "$LOCAL_NAME.torrent" -s"$LOCAL_NAME.$SCRIPT_PID_DATE.part" -U$bandwidthAllocation -e$LEECHER_SEED_HOURS -m$LEECHER_MIN_PEERS > $REDIRECT_STDOUT 2> $REDIRECT_STDERR &
		TORRENT_PID=$!

		# 900 = 15*60 for fifteen minutes to complete (if not done then kill it)
		START=`date +%s`
		END=`expr $START + 900`

		NO_SEEDER_COUNTDOWN="5"

		# check for errors or completion
		while [ 1 ]
		do
			# any error reported then get out of here
			result=`grep -c error $REDIRECT_STDERR `
			if [ "$result" -ge "1" ]
			then
				echo ctorrent download error - no torrent present
				break;
			fi
	
			# "+ x/x/x [y1/y2/y3] m,m | d,u ...
			# y1 = number of pieces completed
			# y2 = total number of pieces 
			# y3 = number of pieces currently available from you
			status=`tail --lines=1 $REDIRECT_STDOUT | cut -d ' ' -f 3 | tr '[' ' ' | tr ']' ' ' | tr '/' ' ' `
			y1=`echo $status | cut -d ' ' -f 1`
			y2=`echo $status | cut -d ' ' -f 2`

			if [ "$y2" = "" ] || [ "$y2" = "is" ]
			then
				# Sometimes "Input channel is now off" and y2 has "is" 
				y2="0"
			fi

			if [ "$y2" -ge "0" ]
			then
				if [ "$y1" = "$y2" ]
				then
					# we are done
					sleep 1
					ln -sf "$LOCAL_NAME.$SCRIPT_PID_DATE.part" "$LOCAL_NAME"
					chmod 777 "$LOCAL_NAME"
					chown silentm:silentm "$LOCAL_NAME"
					break;
				fi

				if [ "$y1" = "0" ]
				then
					# Check for NO_SEEDER_COUNTDOWN
					if [ "$NO_SEEDER_COUNTDOWN" -le "0" ]
					then
						# no seeder so stop ctorrent and remove prealloacted file
						kill -9 $TORRENT_PID
						sleep 4

						#
						# Delete torrent .part files older than one hour
						#
						find $SILENTM_HOME/public_html/multimedia -name "*.part" -type f -mtime +1 -delete
						
						break;
					else
						NO_SEEDER_COUNTDOWN=`expr $NO_SEEDER_COUNTDOWN - 1`
					fi
				fi
			fi

			NOW=`date +%s`
			if [ "$NOW" -gt "$END" ]
			then
				kill -9 $TORRENT_PID
				sleep 4
				
				#
				# Delete torrent .part files older than one hour
				#
				find $SILENTM_HOME/public_html/multimedia -name "*.part" -type f -mtime +1 -delete

				break;
			fi

			sleep 1
		done
	fi
	}

#
# VerifySpace - to verify there is enough space on disk to handle the new file.
#		If not remove old accessed files to make space
#
VerifySpace()
	{
	CDIR=`pwd`

	NEED_SPACE="1"
	while [ "$NEED_SPACE" = "1" ]
	do
		# Grab available space column
		SPACE_ON_PARTITION=$(df -h /home | grep home | awk \{'print $4'\} )

		# Support for Testing (put value in file like "echo 1K > /tmp/space_on_partition" and test
		if [ -e /tmp/space_on_partition ]
		then
			SPACE_ON_PARTITION=`cat /tmp/space_on_partition`
			rm /tmp/space_on_partition
		fi

		if [ -e /etc/debian_version ]; then
			FILE_SIZE_RAW=$(ls -l $FILE_NAME | cut -d' ' -f5)
			SPACE_ON_PARTITION_RAW1K=$(df | grep home | awk '{print $4}')
			SPACE_ON_PARTITION_RAW=$(($SPACE_ON_PARTITION_RAW1K * 1000))
			if [ $FILE_SIZE_RAW -ge $SPACE_ON_PARTITION_RAW ]; then
				NEED_SPACE=1
			else
				NEED_SPACE=0
			fi
		else
			NEED_SPACE=`$SILENTM_HOME/bin/cmdapi -greaterthan "$FILE_SIZE" "$SPACE_ON_PARTITION"`
	
			echo "Checking... $SILENTM_HOME/bin/cmdapi -greaterthan $FILE_SIZE. $SPACE_ON_PARTITION." >> $LOG_FILE
			echo "$DATE smdownload.sh VerifySpace for '$FILE_NAME' (size '$FILE_SIZE'). Available space is '$SPACE_ON_PARTITION'. Need space '$NEED_SPACE'." >> $LOG_FILE
		fi

		if [ "$NEED_SPACE" = "1" ]
		then
			cd $SILENTM_HOME/public_html/multimedia

			# Look at the OLDEST files by last time accessed and remove
			stat -c '%X %n' * | sort -n | head > /tmp/sort_old_access_file
			cat /tmp/sort_old_access_file |\
 			while read SECONDS RM_FILE_NAME
			do
				echo "$DATE smdownload.sh VerifySpace removing $RM_FILE_NAME" >> $LOG_FILE
				rm "$RM_FILE_NAME"         2> /dev/null
				rm "$RM_FILE_NAME.torrent" 2> /dev/null
			done
		fi
	done

	cd "$CDIR"
	}

# 
# Handle downloading of the file.
# Download [local_file_with_path]
#
Download()
	{
	USE_CURL="0"

	rm $REDIRECT_STDOUT 2> /dev/null
	rm $REDIRECT_STDERR 2> /dev/null

	if [ -e /usr/local/bin/ctorrent ]
	then
		GetMetaFile
		StartLeecherClientInstance

		CheckTorrentedFile
		if [ "$TORRENT_COMPLETED_CHECK_OK" = "false" ]
		then
			echo "$DATE WARNING: smdownload.sh TORRENT_COMPLETED_CHECK_OK is false for $FILE_NAME" >> $LOG_FILE
			USE_CURL="1"
		fi

		if [ ! -e "$LOCAL_NAME" ]
		then
			# file not present must have failed so use curl
			USE_CURL="1"
			echo "$DATE smdownload.sh using curl for $FILE_NAME" >> $LOG_FILE
		else
			echo "$DATE smdownload.sh used ctorrent for $LOCAL_NAME" >> $LOG_FILE
		fi
	else
		# No torrent use curl
		USE_CURL="1"
	fi

	if [ "$USE_CURL" = "1" ]
	then
		bandwidthAllocation=`echo "($NIC_SPEED*.90)*122" | bc -l | cut -d '.' -f 1`
		echo "Executing:  /usr/bin/curl \"http://$SERVER_IP/~silentm/multimedia/$FILE_NAME\" -o \"$1.$SCRIPT_PID_DATE.part\" --limit-rate \"$bandwidthAllocation\"K" >> $LOG_FILE
		/usr/bin/curl "http://$SERVER_IP/~silentm/multimedia/$FILE_NAME" -o "$1.$SCRIPT_PID_DATE.part" --limit-rate "$bandwidthAllocation"K > $REDIRECT_STDOUT 2> $REDIRECT_STDERR
		if [ -e /etc/debian_version ]; then
	                result=$(grep "404 Not Found" "$1.$SCRIPT_PID_DATE.part")
	                if [ "$result" = "" ]; then
	    			mv "$1.$SCRIPT_PID_DATE.part" "$1"
				chmod 777 "$1"
				chown silentm:silentm "$1"
			fi
		else
	                result=`grep "404 Not Found" "$1.$SCRIPT_PID_DATE.part" `
	                if [ "$result" == "" ]; then
	    			mv "$1.$SCRIPT_PID_DATE.part" "$1"
				chmod 777 "$1"
				chown silentm:silentm "$1"
			fi
		fi
	fi

	rm $REDIRECT_STDOUT 2> /dev/null
	rm $REDIRECT_STDERR 2> /dev/null
	}

case "$DESIRED_OPTION" in
	'-torrent_get_meta')
		echo ""
		GetMetaFile
		;;
	'-torrent_create_meta')
		echo ""
		CreateTorrentMetaFile
		;;
	'-torrent_seed')
		echo ""
		StartSeederClientInstance
		;;
	'-torrent_leech')
		echo ""
		StartLeecherClientInstance
		;;
	'-check_torrent')
		FILE_NAME="$2"
		CheckTorrentedFile
		if [ "$TORRENT_COMPLETED_CHECK_OK" = "false" ]
		then
			echo Bad 
		else
			echo Good
		fi
		;;
	'-verify')
		VerifySpace
		;;
	'-download')
		if [ -e /etc/redhat-release ]; then
			VerifySpace
		fi
		Download "$LOCAL_NAME"
		;;
	'-voice_evac_download')
		/usr/bin/curl "http://$SERVER_IP/voice_evac/$FILE_NAME" -o "$LOCAL_NAME.$SCRIPT_PID_DATE.part" --limit-rate "$bandwidthAllocation"K > $REDIRECT_STDOUT 2> $REDIRECT_STDERR
		if [ -e /etc/debian_version ]; then
	                result=$(grep "404 Not Found" "$LOCAL_NAME.$SCRIPT_PID_DATE.part")
	                if [ "$result" = "" ]
			then
				ln -sf "$LOCAL_NAME.$SCRIPT_PID_DATE.part" "$LOCAL_NAME"
				chmod 777 "$LOCAL_NAME"
				chown silentm:silentm "$LOCAL_NAME"
			fi
		else
	                result=`grep "404 Not Found" "$LOCAL_NAME.$SCRIPT_PID_DATE.part" `
	                if [ "$result" == "" ]		
			then
				ln -sf "$LOCAL_NAME.$SCRIPT_PID_DATE.part" "$LOCAL_NAME"
				chmod 777 "$LOCAL_NAME"
				chown silentm:silentm "$LOCAL_NAME"
			fi
		fi

        	rm $REDIRECT_STDOUT 2> /dev/null
        	rm $REDIRECT_STDERR 2> /dev/null
		;;
	*)
		echo ""
		echo "WARNING: You must provide additional directives!"
		echo "(view smdownload.sh for details on how to use)"
		echo ""
		;;
esac
