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
STACK=`jq -r .TechStack ./${SITE_ID}.json`
SHIB=`jq -r .Shibboleth ./${SITE_ID}.json`
APP_NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
lowerEnv=`echo "${ENV}" | awk '{print tolower($0)}'`
if [ "${lowerEnv}" == "production" ]; then
  lowerEnv="prod"
fi

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"
ACCT_V1AUTH="{ \"APIKey\": \"${API_KEY}\", \"Password\": \"${API_PSSWD}\" }"

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
  getACCTCookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "acctCookies.txt" -d "${ACCT_AUTH}"`
}

function getServer {
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - MEM") | .UUID' | sed "s/\"//g"`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  echo ${existingServers}
}

function configureMemdserver {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2966"
  elif [ "${DC}" == "GB3" ]; then
    ID="2616"
  elif [ "${DC}" == "IL1" ]; then
    ID="3046"
  elif [ "${DC}" == "UC1" ]; then
    ID="2828"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2246"
  else 
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi
    
  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"59b844c9-1e16-42a0-91d6-9a811efd384c.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"59b844c9-1e16-42a0-91d6-9a811efd384c.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"59b844c9-1e16-42a0-91d6-9a811efd384c.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"59b844c9-1e16-42a0-91d6-9a811efd384c.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"59b844c9-1e16-42a0-91d6-9a811efd384c.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"e359f813-8716-4525-a6c8-ddbce1e05d2b.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"0ca2b5e1-d587-4a5c-a056-afaf6426a00a.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"7ac780f0-9afa-4f19-b8cc-948a2cc2a2dd.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"58a63b8e-7055-4b79-9e07-015434b84fe1.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"4b27d95f-1602-40f2-9cfd-0866efdd0161.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"3a22cee0-8d37-4105-b1e8-107d83500440.TaskServer\",\"Value\":\"${1}\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure Memcached on ${1} for ${ACCT} has been queued. You will get an update every minute."

    # Don't move till configure completed
    getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
    configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
    timer="0"
    while [ ${configurePercent} -ne 100 ]; do
      sleep 60 
      getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
      configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
        if [ ${configurePercent} -eq 0 ]; then
	  getAuth;
          getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
        fi
      echo "`date +"%c"`: Configure ${1} for ${ACCT} is ${configurePercent}% complete..."
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 20 ]; then
        echo "`date +"%c"`: Configure Memcached on ${1} for ${ACCT} has not finished after 20 minutes. Make sure to verify that the blueprint finishes! Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure Memcached on ${1} for ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

# Main
getAuth;
memdServer=$(getServer)
verifyConfigure=`/usr/bin/dig +short ${memdServer}.ko.cld`
if [ -z ${verifyConfigure} ]; then
  configureMemdserver ${memdServer};
else
  echo "`date +"%c"`: Configure Memcached has already been run on ${memdServer}. Moving on..."
fi
