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

#Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Ensure jq is installed
if [ ! `rpm -qa | grep jq-` ]; then
  yum install jq -y
fi

#Eunsure expect is installed
if [ ! `rpm -qa | grep expect-` ]; then
  yum install expect -y
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
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
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

function addSupportCharge {
  getParentNetCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
  if [ ${getParentNetCount} -eq 0 ]; then
   createTrashServer;
  fi
  tier=`echo ${SERVICE_TIER} | awk '{print toupper($0)}'`
  scJSON="{\"servers\":[\"${DC}${ACCT}TRASH01\"],\"package\":{\"packageId\":\"1541fe76-0816-461f-b9ff-5c6d39e87faa\",\"parameters\":{\"ProductCode\":\"COKE-SUPPORT-LEVEL-${tier}\",\"Description\":\"${APP_NAME}\"}}}"
  executePackage=`curl -s "https://${ENDPOINT}/v2/operations/${ACCT}/servers/executePackage" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "${scJSON}"`
  requestURL=`echo ${executePackage} | jq -r '.[] | .links[] | .href'`
  if [ "${requestURL}" == "" ]; then
    echo "`date +"%c"`: The request to Apply Service charge failed, most likely the trash server does not exist. Ensure it is availabe and try again."
  else
    scStatus=`curl -s "https://${ENDPOINT}${requestURL}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r '.status'`
    timer="0"
    while [ "${scStatus}" != "succeeded" ]; do
      echo "`date +"%c"`: Applying service charge to ${ACCT} status: ${scStatus}"
      sleep 30
      scStatus=`curl -s "https://${ENDPOINT}${requestURL}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r '.status'`
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 10 ]; then
        echo "`date +"%c"`: Advanced Services Support Charge FAILED to apply to ${ACCT}. Go run it manually.."
        break
      fi
    done
  fi
  if [ "${scStatus}" == "succeeded" ]; then
    echo "`date +"%c"`: Advanced Services Support Charge applied to ${ACCT}"
    sed -i -e "s/_ServiceCharge_/Applied/g" ./${SITE_ID}.json 
    updateOrchestrate;
  fi
}

function createTrashServer {
  ttl=`date +%FT%TZ -d "+2 days"`
  getGroups=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}"`
  parentGroup=`echo ${getGroups} | jq '.HardwareGroups[] | select(.Name=="Default Group") | .UUID' | sed "s/\"//g"`
  serverJSON="{\"name\": \"Trash\",\"groupId\":\"${parentGroup}\",\"sourceServerId\":\"RHEL-6-64-TEMPLATE\",\"password\":\"svvs123!!\",\"cpu\":2,\"memoryGB\":4,\"type\":\"standard\",\"storageType\":\"standard\",\"ttl\":\"${ttl}\"}"
  trashServer=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}" -XPOST -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "${serverJSON}"`
  trashID=`echo ${trashServer} | jq -r '.links[] | select (.rel=="status") | .href'`
  trashStatus=`curl -s "https://${ENDPOINT}/${trashID}" -XPOST -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r .status`
  timer="0"
  until [ ${trashStatus} == "succeeded" ]; do
    sleep 30
    trashStatus=`curl -s "https://${ENDPOINT}/${trashID}" -XPOST -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r .status`
    echo "`date +"%c"`: Trash Server status for ${ACCT}: ${trashStatus}"
    timer=$(( timer + 1 ))
    if [ ${timer} == 15 ]; then
      break
    fi
  done

  if [ "${trashStatus}" == "succeeded" ]; then
    echo "`date +"%c"`: The trash server for ${ACCT} has been created"
  else
    echo "`date +"%c"`: Trash server was not created, Bailing!!"
    exit 1
  fi

}

## Main
getAuth;
getSiteInfo;
#updateOrchestrate;
#exit

# Only apply service charge if it has not been applied before
if [ "${SERV_CHRG}" != "Applied" ]; then
  addSupportCharge;
fi

if [[ ${SEC_TIER} -eq 1 && "${ENV}" == "Production" || ${SEC_TIER} -eq 2 && "${ENV}" == "Production" ]]; then
  ./alogic_build.sh ${SITE_ID} ${ENV} ${ADD_DC}
fi
if [[ "${STACK}" == "Lamp" || "${STACK}" == "Java" ]]; then
  # Web and/or App Server Build
  if [ "${STACK}" == "Lamp" ]; then
    ./web_build.sh ${SITE_ID} ${ENV} "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
    web_build="$?"
    if [ ${web_build} -ne 0 ]; then
      exit ${web_build}
    fi
  elif [ "${STACK}" == "Java" ]; then
    ./java_build.sh ${SITE_ID} ${ENV} "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
    java_build="$?"
    if [ ${java_build} -ne 0 ]; then
      exit ${java_build}
    fi
  fi
  
  # DB build
  if [ "${DBAAS}" == "true" ]; then 
    ./rdbs_build.sh ${SITE_ID} ${ENV}
    rdbs_build="$?"
    if [ ${rdbs_build} -ne 0 ]; then
      exit ${rdbs_build}
    fi
  else
    ./mysql_build.sh ${SITE_ID} ${ENV} "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
    mysql_build="$?"
    if [ ${mysql_build} -ne 0 ]; then
      exit ${mysql_build}
    fi
  fi
elif [ "${STACK}" == "IIS" ]; then
  ./iis_build.sh ${SITE_ID} ${ENV} ${API_KEY} ${API_PSSWD} ${ADD_DC}
  iis_build="$?"
  if [ ${iis_build} -ne 0 ]; then
    exit ${iis_build}
  fi
  ./mssql_build.sh ${SITE_ID} ${ENV} ${API_KEY} ${API_PSSWD} ${ADD_DC}
  mssql_build="$?"
  if [ ${mssql_build} -ne 0 ]; then
    exit ${mssql_build}
  fi
else
  echo "Tech Stack not specified!"
fi

  # Build Memcached if needed
if [[ "${MEMCD}" == "true" || "${MEMCD}" == "True" ]]; then
  ./memd_build.sh ${SITE_ID} ${ENV} "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
  memd_build="$?"
  if [ ${memd_build} -ne 0 ]; then
    exit ${memd_build}
  fi
fi

# Build Fileserver if needed
if [[ "${FLSRV}" == "true" || "${FLSRV}" == "True" ]]; then
  ./fs_build.sh ${SITE_ID} ${ENV} "${API_KEY}" "${API_PSSWD}" ${ADD_DC}
  fs_build="$?"
  if [ ${fs_build} -ne 0 ]; then
    exit ${fs_build}
  fi
fi

# Cleanup
updateOrchestrate;
rm ./${SITE_ID}.json
