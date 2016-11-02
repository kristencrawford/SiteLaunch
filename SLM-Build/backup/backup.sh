#!/bin/bash
IFS='%'
SITE_ID="${1}"
ENV="${2}"
ADD_DC="${3}"

#API Varibles
ENDPOINT="api.ctl.io"
BKP_ENDPOINT="api-va1.backup.ctl.io"
V2AUTH="{ \"username\": \" <v2 username> \", \"password\": \" <v2 password> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 password> \" }"

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
    ACCT=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Alias' ./${SITE_ID}.json`
    if [ ${ACCT} == "null" ]; then
      ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
    fi
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    SERVICE_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    STACK=`jq -r .TechStack ./${SITE_ID}.json`
    REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
    FILESERVER=`jq -r .FileServer ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function acctPolicy {
  if [ "${ENV}" == "Test" ]; then
    days="15"
  elif [ "${ENV}" == "Production" ]; then
    days="31"
  fi

  if [ "${1}" == "Web" ]; then
    if [ "${REF_ARCH}" == "Basic" ]; then
      paths="\"/opt/web/${SITE_ID}/\""
    else
      paths="\"/opt/web/${SITE_ID}/logs/\""
    fi
  elif [ "${1}" == "App" ]; then
    if [ "${REF_ARCH}" == "Basic" ]; then
      paths="\"/opt/web/${SITE_ID}/\",\"/opt/app/${SITE_ID}/\""
    else
      paths="\"/opt/web/${SITE_ID}/logs/\",\"/opt/app/${SITE_ID}/logs/\""
    fi
  elif [ "${1}" == "MySql" ]; then
    paths="\"/data01/meb/\",\"/data01/mysql/binlog/\""
  elif [ "${1}" == "IIS" ]; then
    if [ "${REF_ARCH}" == "Basic" ]; then
      paths="\"E:\\\SharedFiles\",\"E:\\\opt\\\web\\\1\\\content\\\htdocs\""
    else
      paths="\"E:\\\SharedFiles\""
    fi
  elif [ "${1}" == "MsSql" ]; then
    upperEnv=`echo "${ENV}" | awk '{print toupper($0)}'`
    if [ "${upperEnv}" == "PRODUCTION" ]; then
      upperEnv="PROD"
    fi
    paths="\"E:\\\MSSQL12.KO${SITE_ID}MS${upperEnv}\\\MSSQL\\\BACKUP\""
  elif [ "${1}" == "FileServer" ]; then
    paths="\"/opt/NAS/\""
  else
    echo "`date +"%c"`: Unrecognized input: ${1}! Bailing.."
  fi

  backupJSON="{\"backupIntervalHours\":24,\"clcAccountAlias\":\"${ACCT}\",\"name\":\"${SITE_ID}-${ENV}-${1}\",\"osType\":\"${2}\",\"paths\":[${paths}],\"excludedDirectoryPaths\":[],\"retentionDays\":${days},\"status\":\"ACTIVE\"}"

  createPolicy=`curl -s --tlsv1.1 "https://${BKP_ENDPOINT}/clc-backup-api/api/accountPolicies" -H "Authorization: Bearer ${TOKEN}" -X POST --header "Content-Type: application/json" --header "Accept: application/json" --header "CLC-ALIAS:${ACCT}" -d "${backupJSON}"`

  policyID=`echo ${createPolicy} | jq -r .policyId 2> /dev/null`
  if [ "${policyID}" != "" ]; then
    echo ${policyID}
  fi
  
}

function serverPolicy {
  policyCheck=`curl -s --tlsv1.1 "https://${BKP_ENDPOINT}/clc-backup-api/api/accountPolicies/${2}/serverPolicies" -XPUT -H "Authorization: Bearer ${TOKEN}" -XGET --header "Content-Type: application/json" --header "Accept: application/json" --header "CLC-ALIAS:${ACCT}" | jq -r '.results[] | select(.serverId=="'${1}'") | .status'`
  if [ "${policyCheck}" == "" ]; then
    if [[ "${DC}" == "VA1" || "${DC}" == "UC1" ]]; then
      region="GERMANY"
    else
      region="CANADA"
    fi
    serverJSON="{\"clcAccountAlias\":\"${ACCT}\",\"serverId\":\"${1}\",\"storageRegion\":\"${region}\"}"
    serverPolicy=`curl -s --tlsv1.1 "https://${BKP_ENDPOINT}/clc-backup-api/api/accountPolicies/${2}/serverPolicies" -XPUT -H "Authorization: Bearer ${TOKEN}" -X POST --header "Content-Type: application/json" --header "Accept: application/json" --header "CLC-ALIAS:${ACCT}" -d "${serverJSON}"`
    policyID=`echo ${serverPolicy} | jq -r .serverPolicyId`
    status=`echo ${serverPolicy} | jq -r .status`
    if [ "${policyID}" != "" ]; then
      echo "`date +"%c"`: Server Policy #${policyID} has been created on ${1} and the status is: ${status}"
    else
      echo "`date +"%c"`: Server Policy on ${1} failed! Go figure out why and/or try again. Bailing..."
      exit 1
    fi
  else
    echo "`date +"%c"`: Server Policy on ${1} already exists and has a status of: ${policyCheck}"
  fi
}

getAuth;
getSiteInfo;
getExisting=`curl -s --tlsv1.1 "https://api.backup.ctl.io/clc-backup-api/api/accountPolicies" -XPUT -H "Authorization: Bearer ${TOKEN}" -XGET --header "Content-Type: application/json" --header "Accept: application/json" --header "CLC-ALIAS:${ACCT}"`
if [ "${STACK}" == "Lamp" ]; then
  webPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-Web") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
  if [ "${webPolicyID}" == "" ]; then
    webPolicyID=$(acctPolicy Web Linux)
    if [ "${webPolicyID}" != "" ]; then
      echo "`date +"%c"`: Policy #${webPolicyID} was created for ${SITE_ID}-${ENV}-Web"
    else
      echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-Web failed!"
      exit 1
    fi
  else
    echo "`date +"%c"`: Policy #${webPolicyID} already exists for ${SITE_ID}-${ENV}-Web. Moving on..."
  fi
  if [ "${DBAAS}" == "false" ]; then
    mysqlPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-MySql") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
    if [ "${mysqlPolicyID}" == "" ]; then
      mysqlPolicyID=$(acctPolicy MySql Linux)
      if [ "${mysqlPolicyID}" != "" ]; then
        echo "`date +"%c"`: Policy #${mysqlPolicyID} was created for ${SITE_ID}-${ENV}-MySql"
      else
        echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-MySql failed!"
        exit 1
      fi
    else
      echo "`date +"%c"`: Policy #${mysqlPolicyID} already exists for ${SITE_ID}-${ENV}-MySql. Moving on..."
    fi
  fi
elif [ "${STACK}" == "Java" ]; then
  appPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-App") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
  if [ "${appPolicyID}" == "" ]; then
    appPolicyID=$(acctPolicy App Linux)
    if [ "${appPolicyID}" != "" ]; then
      echo "`date +"%c"`: Policy #${appPolicyID} was created for ${SITE_ID}-${ENV}-App"
    else
      echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-App failed!"
      exit 1
    fi
  else
    echo "`date +"%c"`: Policy #${appPolicyID} already exists for ${SITE_ID}-${ENV}-App. Moving on..."
  fi
  if [ "${DBAAS}" == "false" ]; then
    mysqlPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-MySql") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
    if [ "${mysqlPolicyID}" == "" ]; then
      mysqlPolicyID=$(acctPolicy MySql Linux)
      if [ "${mysqlPolicyID}" != "" ]; then
        echo "`date +"%c"`: Policy #${mysqlPolicyID} was created for ${SITE_ID}-${ENV}-MySql"
      else
        echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-MySql failed!"
        exit 1
      fi
    else
      echo "`date +"%c"`: Policy #${mysqlPolicyID} already exists for ${SITE_ID}-${ENV}-MySql. Moving on..."
    fi
  fi
elif [ "${STACK}" == "IIS" ]; then
  iisPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-IIS") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
  if [ "${iisPolicyID}" == "" ]; then
    iisPolicyID=$(acctPolicy IIS Windows)
    if [ "${iisPolicyID}" != "" ]; then
      echo "`date +"%c"`: Policy #${iisPolicyID} was created for ${SITE_ID}-${ENV}-IIS"
    else
      echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-IIS failed!"
      exit 1
    fi
  else
    echo "`date +"%c"`: Policy #${iisPolicyID} already exists for ${SITE_ID}-${ENV}-IIS. Moving on..."
  fi
  mssqlPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-MsSql") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
  if [ "${mssqlPolicyID}" == "" ]; then
    mssqlPolicyID=$(acctPolicy MsSql Windows)
    if [ "${mssqlPolicyID}" != "" ]; then
      echo "`date +"%c"`: Policy #${mssqlPolicyID} was created for ${SITE_ID}-${ENV}-MsSql"
    else
      echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-MsSql failed!"
      exit 1
    fi
  else
    echo "`date +"%c"`: Policy #${mssqlPolicyID} already exists for ${SITE_ID}-${ENV}-MsSql. Moving on..."
  fi
fi

if [ "${FILESERVER}" == "true" ]; then
  fsPolicyID=`echo ${getExisting} | jq -r '.results[] | select(.name=="'${SITE_ID}'-'${ENV}'-FileServer") | select(.status=="ACTIVE") | .policyId' 2> /dev/null`
  if [ "${fsPolicyID}" == "" ]; then
    fsPolicyID=$(acctPolicy FileServer Linux)
    if [ "${fsPolicyID}" != "" ]; then
      echo "`date +"%c"`: Policy #${fsPolicyID} was created for ${SITE_ID}-${ENV}-FileServer"
    else
      echo "`date +"%c"`: Policy for ${SITE_ID}-${ENV}-FileServer failed!"
      exit 1
    fi
  else
    echo "`date +"%c"`: Policy #${fsPolicyID} already exists for ${SITE_ID}-${ENV}-FileServer. Moving on..."
  fi
fi

acctServers=`curl -s --tlsv1.1 "https://${BKP_ENDPOINT}/clc-backup-api/api/datacenters/${DC}/servers" -H "Authorization: Bearer ${TOKEN}" -XGET --header "Content-Type: application/json" --header "Accept: application/json" --header "CLC-ALIAS:${ACCT}"`
serverCount=`echo ${acctServers} | jq length`
for (( s=0 ; s<${serverCount} ; s++ )); do
  serverName=`echo ${acctServers} | jq -r '.['${s}']' | awk '{print toupper($0)}'`
  if [[ "${serverName}" =~ "WEB" ]]; then
    serverPolicy ${serverName} ${webPolicyID}
  elif [[ "${serverName}" =~ "WA" ]]; then
    serverPolicy ${serverName} ${appPolicyID}
  elif [[ "${serverName}" =~ "MYSQL" ]]; then
    serverPolicy ${serverName} ${mysqlPolicyID}
  elif [[ "${serverName}" =~ "IIS" ]]; then
    serverPolicy ${serverName} ${iisPolicyID}
  elif [[ "${serverName}" =~ "MSSQL" ]]; then
    serverPolicy ${serverName} ${mssqlPolicyID}
  elif [[ "${serverName}" =~ "FS" ]]; then
    serverPolicy ${serverName} ${fsPolicyID}
  fi
done

#cleanup
rm ./${SITE_ID}.json
