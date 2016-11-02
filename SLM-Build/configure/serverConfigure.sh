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
#    serverBuilds.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Add Site Support Charge
#    Get site json from orchestrate and build all needed servers based on info from the json
#    Add Public VIP to all Basic, Security Tier 3 sites
#
#### Changelog
#
##   2016.01.05 <kristen.crawford@centurylink.com>
## - Initial release
#
## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
API_KEY="${3}"
API_PSSWD="${4}"
ADD_DC="${5}"

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"
ACCT_V1AUTH="{ \"APIKey\": \"${API_KEY}\", \"Password\": \"${API_PSSWD}\" }"

#NOTE# Orchestrate.io Information
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
    DC=`jq -r .Datacenter ./${SITE_ID}.json`
    SERVICE_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    STACK=`jq -r .TechStack ./${SITE_ID}.json`
    MEMCD=`jq -r .Memcached ./${SITE_ID}.json`
    FLSRV=`jq -r .FileServer ./${SITE_ID}.json`
    REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
    SEC_TIER=`jq -r .SecurityTier ./${SITE_ID}.json`
    SERV_CHRG=`jq -r .ServiceCharge ./${SITE_ID}.json`
    APP_NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

#getAuth;
#bpParam=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetBlueprintParameters/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"ID\":\"3174\"}"`
#echo "${bpParam}"
#exit

#getAuth;
#scStatus=`curl -s "https://${ENDPOINT}/v2/operations/k0d9/status/gb3-86606" -XPUT -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r '.status'`
#echo "${scStatus}"
#exit

## Main
getAuth;
getSiteInfo;
#updateOrchestrate;
#exit
if [[ "${STACK}" == "Lamp" || "${STACK}" == "Java" ]]; then
  if [ "${STACK}" == "Lamp" ]; then
    ./web_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
    web_configure="$?"
    if [ ${web_configure} -ne 0 ]; then
      exit ${web_configure}
    fi
  elif [ "${STACK}" == "Java" ]; then
    ./java_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
    java_configure="$?"
    if [ ${java_configure} -ne 0 ]; then
      exit ${java_configure}
    fi
  fi
 
  if [ "${DBAAS}" == "false" ]; then
    ./mysql_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
    mysql_configure="$?"
    if [ ${mysql_configure} -ne 0 ]; then
      exit ${mysql_configure}
    fi
  fi
elif [ "${STACK}" == "IIS" ]; then
  ./iis_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
  iis_configure="$?"
  if [ ${iis_configure} -ne 0 ]; then
    exit ${iis_configure}
  fi
  ./mssql_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
  mssql_configure="$?"
  if [ ${mssql_configure} -ne 0 ]; then
    exit ${mssql_configure}
  fi
else
  echo "Tech Stack not specified!"
fi

# Build Fileserver if needed
if [[ "${FLSRV}" == "True" ||  "${FLSRV}" == "true" ]]; then
  ./fs_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
  fs_configure="$?"
  if [ ${fs_configure} -ne 0 ]; then
    exit ${fs_configure}
  fi
fi

# Build Memcached if needed
if [[ "${MEMCD}" == "True" ||  "${MEMCD}" == "true" ]]; then
  ./memd_configure.sh "${SITE_ID}" "${ENV}" "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
  memd_configure="$?"
  if [ ${memd_configure} -ne 0 ]; then
    exit ${memd_configure}
  fi
fi

# cleanup
rm ./${SITE_ID}.json
