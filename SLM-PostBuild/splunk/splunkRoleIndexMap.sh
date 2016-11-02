#!/bin/bash
# Script to create/modify indexes mapped to roles and
# verify/map LDAP groups to roles in Splunk.
# Written by: David Stephens <david.stephens@centurylink.com>
# Date: 2/5/2016
# Version: 1
# Notes: Initial draft

# Modified by: David Stephens <david.stephens@centurylink.com>
# Date: 4/1/2016
# Version: 1.5
# Notes: added LDAP to Role mapping

# Modified by: David Stephens <david.stephens@centurylink.com>
# Date: 4/4/2016
# Version: 1.6
# Notes: added index creation

# Modified by: David Stephens <david.stephens@centurylink.com>
# Date: 4/5/2016
# Version: 1.7
# Notes: added CLI variable checks

# Create a format check for CLI variable $1
CLI_FORMAT="[0-9][0-9][0-9][0-9][0-9][0-9]"

#CLI variable checks
if [ "$#" -eq 0 ] || [ "$2" = "" ]; then
	echo
	echo "Incorrect syntax!"
	echo "Please execute as follows:"
	echo "# ./splunkRoleIndexMap.sh <SITE_ID> <ENVIRONMENT>"
	exit 1
fi

if [[ "$1" != $CLI_FORMAT ]]; then
	echo
	echo "SITE_ID is incorrect."
	echo "Format should be 6 numerical digits."
	echo "i.e. 886644"
	exit 1
fi

#CLI variables
SITE_ID=$1

case "$2" in
	"Production") ENV="prod"
	;;
	"Test") ENV="test"
	;;
	*) ENV="${2,,}"
	;;
esac

#Create log file
LOG_FILE="/opt/ko/scripts/CLC/platform/SiteLaunch/KO-SLM-PostBuild/splunk/log/$1_Splunk.log"
touch $LOG_FILE

INDEX=$SITE_ID"-"$ENV

#Initialize newROLE variable for use later
newROLE=0

#NOTE# Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Ensure jq is installed
if [ ! `rpm -qa | grep jq-` ]; then
  yum install jq -y
fi

#Get site info from JSON
  getIndex=`curl -s "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XGET -H "Content-Type: application/json" -u "$ORCH_APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .code`

  if [ "$checkIndex" != "items_not_found" ]; then
    echo $getIndex > ./${SITE_ID}.json
    ROLE=`jq .SiteGroup ./${SITE_ID}.json | sed "s/\"//g"`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi

# check ROLE variable for spaces and correct to %20 for use with curl
case "$ROLE" in
        *\ * )
                  curlROLE=`echo "$ROLE" | sed 's/ /%20/g'`
                  ;;
        *)
                  curlROLE="$ROLE"
                  ;;
esac

#Check which environment
chkENV=`hostname`
case "$chkENV" in
        "VA1KODVLMS01.va1.savvis.net") splunkIP="10.135.32.31"
        DC="dev"
        ;;
        "VA1TCCCLMS0102.va1.savvis.net") splunkIP="10.128.138.26"
        DC="va1"
        ;;
        "UC1TCCCLMS01.uc1.savvis.net") splunkIP="10.122.52.23"
        DC="uc1"
        ;;
        "GB3TCCCLMS01.gb3.savvis.net") splunkIP="10.106.30.25"
        DC="gb3"
        ;;
        "SG1TCCCLMS01.sg1.savvis.net") splunkIP="10.130.82.25"
        DC="sg1"
        ;;
	"IL1TCCCLMS01.il1.savvis.net") splunkIP="10.93.21.27"
        DC="il1"
	;;
        *)
        echo "Environment unrecognised, Please execute this script in the correct environment."
        exit 1
        ;;
esac

#Splunk Master variable
INDEX_MASTER="splunk-index-master.$DC.ko.cld"

# Create a format check for site indexes
# This is to keep index names in check
SITE_FORMAT="[0-9][0-9][0-9][0-9][0-9][0-9]-[a-z]*"

# updateBundle.sh path
UPDATE_BUNDLE="/opt/ko/scripts/splunk/updateBundle.sh"

# updatePeers.sh path
UPDATE_PEERS="/opt/ko/scripts/splunk/updatePeers.sh"

#Check/Create index
if [[ "$INDEX" = $SITE_FORMAT ]]; then
    ssh $INDEX_MASTER "sudo $UPDATE_BUNDLE $INDEX" &> /dev/null
    ssh $INDEX_MASTER "sudo $UPDATE_PEERS" &> /dev/null
  else
    critical "$INDEX fails to follow the index naming standard and will not be created."
    exit 1
fi

#Check if role exists
chkROLE=`curl -s -S -k -u user:password https://$splunkIP:8089/services/authorization/roles/$curlROLE | grep -c "Could not find"`

#If role does not exist, create it and assign the indexes to it.
if [ "$chkROLE" == "1" ]; then
        curl -k -u user:password https://$splunkIP:8089/services/authorization/roles \
        -d name="$ROLE" \
        -d imported_roles=user \
        -d defaultApp=search \
        -d srchIndexesAllowed=$INDEX \
        &> $LOG_FILE
        newROLE="1"
fi

#Verify ROLE is mapped to LDAP group and if not, map it
ldapCURL=`curl -s -S -k -u user:password https://$splunkIP:8089/servicesNS/-/launcher/user/LDAP-groups/Development%20Agencies%2C$curlROLE?"output_mode=json" | jq -r '.entry[] | .content | .roles[]'`
if [ "$ldapCURL" == "" ]; then
        curl -s -S -k -u user:password https://$splunkIP:8089/servicesNS/-/launcher/user/LDAP-groups/Development%20Agencies%2C$curlROLE -d roles="$ROLE" &> $LOG_FILE
fi

if [ "$newROLE" != "1" ]; then
  #If role already exists, gather the existing allowed indexes in array
  existIndex=`curl -k -s -S -u user:password https://$splunkIP:8089/services/authorization/roles/$curlROLE?"output_mode=json" | jq -r '.entry[] | .content | .srchIndexesAllowed[]'`

  #define base splunk CMD
  baseSpCMD="curl -s -S -k -u user:password https://$splunkIP:8089/services/authorization/roles/$curlROLE "

  #prep existing indexes into command format
  counter=0

  for i in ${existIndex[@]}
  do
        cmdExistIndex[$counter]="-d srchIndexesAllowed=$i "
        counter=$((counter+1))
  done

  #prep new index into command format
  cmdNewIndex="-d srchIndexesAllowed=$INDEX"

  #build/execute modify role command
  eval $baseSpCMD ${cmdExistIndex[@]} $cmdNewIndex &> $LOG_FILE
fi

#Error checking to confirm Index was added to Role
existIndex=`curl -k -s -S -u user:password https://$splunkIP:8089/services/authorization/roles/$curlROLE?"output_mode=json" | jq -r '.entry[] | .content | .srchIndexesAllowed[]'`

if [ `echo $existIndex | grep -c "$INDEX"` = 1 ]; then
	echo "$INDEX added to $ROLE"
	exit 0
else
	echo "$INDEX not added to $ROLE, please contact KO_Web team."
	exit 1
fi

#Remove JSON files
rm -f ./*.json
