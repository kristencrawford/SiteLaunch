#!/bin/bash

#
#     _____            _                    _     _       _      _____ _                 _
#     /  __ \          | |                  | |   (_)     | |    /  __ \ |               | |
#     | /  \/ ___ _ __ | |_ _   _ _ __ _   _| |    _ _ __ | | __ | /  \/ | ___  _   _  __| |
#     | |    / _ \ '_ \| __| | | | '__| | | | |   | | '_ \| |/ / | |   | |/ _ \| | | |/ _` |
#     | \__/\  __/ | | | |_| |_| | |  | |_| | |___| | | | |   <  | \__/\ | (_) | |_| | (_| |
#      \____/\___|_| |_|\__|\__,_|_|   \__, \_____/_|_| |_|_|\_\  \____/_|\___/ \__,_|\__,_|
#                                        __/ |
#                                       |___/
#
#    createGroups.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Create server groups for requested environments
#
#### Changelog
#
##   2015.11.24 <kristen.crawford@centurylink.com>
## - Initial release


## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ADD_DC="${2}"

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"
ACCT_V1AUTH="{ \"APIKey\": \"${API_KEY}\", \"Password\": \"${API_PSSWD}\" }"

#Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Ensure jq is installed
if [ ! `rpm -qa | grep jq-` ]; then
  yum install jq -y
fi

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
}

function getSiteInfo {
  getIndex=`curl -s "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XGET -H "Content-Type: application/json" -u "$ORCH_APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .code`

  if [ "$checkIndex" != "items_not_found" ]; then
    echo $getIndex > ./${SITE_ID}.json
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    GET_ENV=`jq -r '.Environments[] | select(.Requested=="True") | .Name' ./${SITE_ID}.json`
    ENV=`echo -n "$GET_ENV"|tr '\n' ','`
    ALOGIC=`jq -r .SecurityTier ./${SITE_ID}.json`
    MEMD=`jq -r .Memcached ./${SITE_ID}.json`
    FILESERVER=`jq -r .FileServer ./${SITE_ID}.json`
    TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function createGroups() {
  ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json 2> /dev/null`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi
  getGroups=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}"`
  parentGroup=`echo ${getGroups} | jq -r '.HardwareGroups[] | select(.Name=="'${DC}' Hardware") | .UUID'`
  #Check to see if group exists before making it
  groupName=`echo ${getGroups} | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${1}' - '${2}'") | .UUID'`
  if [ -z ${groupName} ]; then
    createGroup=`curl -s "https://${ENDPOINT}/v2/groups/${ACCT}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "{\"name\":\"${SITE_ID} - ${1} - ${2}\",\"description\":\"${SITE_ID} - ${1} - ${2}\",\"parentGroupId\":\"${parentGroup}\"}"`
    groupStatus=`echo ${createGroup} | jq .status`
    echo "`date +"%c"`: ${SITE_ID} - ${1} - ${2} group is ${groupStatus}"
  else
    echo "`date +"%c"`: ${SITE_ID} - ${1} - ${2} group exists, moving on.."
  fi
}

function createMetalgroup {
  # Check for existing group before creating new
  ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi
  getGroups=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}"`
  metalGroupName=`echo ${getGroups} | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - Medal: '${TIER}'") | .UUID'`
  if [ -z ${metalGroupName} ]; then
    parentGroup=`echo ${getGroups} | jq -r '.HardwareGroups[] | select(.Name=="'${DC}' Hardware") | .UUID'`
    createMetalGroup=`curl -s "https://${ENDPOINT}/v2/groups/${ACCT}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "{\"name\":\"${SITE_ID} - Medal: ${TIER}\",\"description\":\"${SITE_ID} - Medal: ${IER}\",\"parentGroupId\":\"${parentGroup}\"}"`
    metalStatus=`echo ${createMetalGroup} | jq .status`
    echo "`date +"%c"`: ${SITE_ID} - Medal: ${TIER} group is ${metalStatus}"
  else
    echo "`date +"%c"`: ${SITE_ID} - Medal: ${TIER} group exists, moving on.."
  fi
}

## Main ##
#get auth credentials for api 1 and 2
getAuth;
getSiteInfo;
NUMENV=`echo $ENV | awk -F "," '{print NF-1}'`
NUMENV=$(( NUMENV + 1 ))
for (( k = 1 ; k <= ${NUMENV} ; k++ )); do
  unset currentEnv
  currentEnv=`echo $ENV | awk -F "," '{print $'$k'}'`
  createGroups ${currentEnv} WEB
  if [ "${DBAAS}" == "false" ]; then
    createGroups ${currentEnv} DB
  fi
  if [ ${MEMD} == "true" ]; then
    createGroups ${currentEnv} MEM
  fi
  if [ ${FILESERVER} == "true" ]; then
    createGroups ${currentEnv} FS
  fi
  if [ "${currentEnv}" == "Production" ]; then
    if [[ ${ALOGIC} -eq 1 || ${ALOGIC} -eq 2 ]]; then
      createGroups ${currentEnv} DMZ
    fi
  fi
  createMetalgroup ${currentEnv}
done

# cleanup
rm ./${SITE_ID}.json
