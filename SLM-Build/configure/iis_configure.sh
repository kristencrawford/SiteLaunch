## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
API_KEY="${3}"
API_PSSWD="${4}"
ADD_DC="${5}"
if [ "${ADD_DC}" == "" ]; then
  DC=`jq -r .Datacenter ./${SITE_ID}.json`
else
  DC="${ADD_DC}"
fi
ACCT=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Alias' ./${SITE_ID}.json`
if [ ${ACCT} == "null" ]; then
  ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
fi
REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
SERV_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
APP_NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
lowerEnv=`echo "${ENV}" | awk '{print tolower($0)}'`
if [ "${lowerEnv}" == "production" ]; then
  lowerEnv="prod"
fi
## Ensure that Test builds only get 1 master db even if the site is standard
if [ "${ENV}" == "Test" ]; then
  REF_ARCH="Basic"
fi

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"
ACCT_V1AUTH="{ \"APIKey\": \"${API_KEY}\", \"Password\": \"${API_PSSWD}\" }"


#NOTE# Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
  getACCTCookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "acctCookies.txt" -d "${ACCT_AUTH}"`
}

function getIISServers {
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - WEB") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  echo ${existingServers}
}

function configureBasic {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2911"
  elif [ "${DC}" == "GB3" ]; then
    ID="2563"
  elif [ "${DC}" == "IL1" ]; then
    ID="2993"
  elif [ "${DC}" == "UC1" ]; then
    ID="2772"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2191"
  else 
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi
    
  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"71958d3a-e0b9-4d41-9d85-607bbfac4d97.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"71958d3a-e0b9-4d41-9d85-607bbfac4d97.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"71958d3a-e0b9-4d41-9d85-607bbfac4d97.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"71958d3a-e0b9-4d41-9d85-607bbfac4d97.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"71958d3a-e0b9-4d41-9d85-607bbfac4d97.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"3cbc0118-9a4c-48a9-9952-671249a8304e.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"40cb1c12-a1ae-4d04-a597-66a35a8bd98a.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"40cb1c12-a1ae-4d04-a597-66a35a8bd98a.Description\",\"Value\":\"${APP_NAME}\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure IIS Basic for ${1} on ${ACCT} has been queued. You will get an update every minute."

    # Don't move till configure completed
    getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
    configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
    timer="0"
    while [ ${configurePercent} -ne 100 ]; do
      sleep 60
      getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
      configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      # The cookie timesout after like 15 minutes.. As this takes longer than 15 minutes, it must be refreshed
      if [ ${configurePercent} -eq 0 ]; then
	getAuth;
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      fi
      echo "`date +"%c"`: Configure ${1} for ${ACCT} is ${configurePercent}% complete..."
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 30 ]; then
        echo "`date +"%c"`: Configure IIS Basic for ${1} on ${ACCT} has not finished after 30 minutes. Make sure to verify that the blueprint finishes. Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure IIS Basic for ${1} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

function configureStandard {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2987"
  elif [ "${DC}" == "GB3" ]; then
    ID="2637"
  elif [ "${DC}" == "IL1" ]; then
    ID="3067"
  elif [ "${DC}" == "UC1" ]; then
    ID="2849"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2267"
  else
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
  fi

  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"d9e776fc-cdd4-4eaf-88f1-0774893e5e72.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"d9e776fc-cdd4-4eaf-88f1-0774893e5e72.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"d9e776fc-cdd4-4eaf-88f1-0774893e5e72.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"d9e776fc-cdd4-4eaf-88f1-0774893e5e72.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"d9e776fc-cdd4-4eaf-88f1-0774893e5e72.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"8b2de187-a1d0-493e-a1f1-f45bc5188990.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"8a172801-a932-49aa-b95e-6396e3a2c9a4.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"8a172801-a932-49aa-b95e-6396e3a2c9a4.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"8a172801-a932-49aa-b95e-6396e3a2c9a4.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"8a172801-a932-49aa-b95e-6396e3a2c9a4.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"8a172801-a932-49aa-b95e-6396e3a2c9a4.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"030489fb-f120-4315-909e-91445cb39a43.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"84afdd3e-6de5-41c3-a48d-40ca1488c7f1.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"84afdd3e-6de5-41c3-a48d-40ca1488c7f1.Description\",\"Value\":\"${APP_NAME}\"},{\"Name\":\"c29e247d-d383-4c86-9786-80c534408b51.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"c29e247d-d383-4c86-9786-80c534408b51.Description\",\"Value\":\"${APP_NAME}\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure IIS for ${1} and ${2} on ${ACCT} have been queued. You will get an update every 2 minutes, but please be patient!  This process could take up to an hour."

    # Don't move till configure completed
    getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
    configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
    timer="0"
    while [ ${configurePercent} -ne 100 ]; do
      sleep 120
      getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
      configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      # The cookie timesout after like 15 minutes.. As this takes longer than 15 minutes, it must be refreshed
      if [ ${configurePercent} -eq 0 ]; then
	getAuth;
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      fi
      echo "`date +"%c"`: Configure ${1} and ${2} for ${ACCT} is ${configurePercent}% complete..."
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 20 ]; then
        echo "`date +"%c"`: Configure IIS for ${1} and ${2} on ${ACCT} have not finished after 40 minutes. Make sure to verify that the blueprint finishes. Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure IIS for ${1} and ${2} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

# Main
getAuth;
found=$(getIISServers)
declare -a "servers=($found)"
if [ "${REF_ARCH}" == "Basic" ]; then
  # Verify if configure has already been run
  middleware=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware' ./${SITE_ID}.json`
  if [ "${middleware}" != "Completed" ]; then
    getAuth;
    configureBasic ${servers[0]};
    if [ ${?} -ne 1 ]; then
      # Update JSON marking server middleware completed
      newJSON=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware) |= "Completed"' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${newJSON} > ./${SITE_ID}.json
      updateOrchestrate;
    fi
  else
    echo "`date +"%c"`: Configure IIS Basic has already been run on ${servers[0]}. Moving on..."
  fi
elif [ "${REF_ARCH}" == "Standard" ]; then
  middleware1=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware' ./${SITE_ID}.json`
  middleware2=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[1]}'") | .Middleware' ./${SITE_ID}.json`
  if [[ "${middleware1}" != "Completed" && "${middleware2}" != "Completed" ]]; then
    getAuth;
    configureStandard ${servers[0]} ${servers[1]};
    if [ ${?} -ne 1 ]; then
      # Update JSON marking server middleware completed
      newJSON1=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware) |= "Completed"' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${newJSON1} > ./${SITE_ID}.json
      newJSON=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[1]}'") | .Middleware) |= "Completed"' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${newJSON2} > ./${SITE_ID}.json
      updateOrchestrate;
    fi
  else
    echo "`date +"%c"`: Configure IIS Standard has already been run on: ${servers[0]} and ${servers[1]}. Moving on..."
  fi
else
  echo "No Reference Architecture Found! This shouldn't have happened!! Bailing..."
  exit 1
fi
