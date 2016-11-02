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

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
  getACCTCookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "acctCookies.txt" -d "${ACCT_AUTH}"`
}

function getWebservers {
  # Check webserver total before creating any servers
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - WEB") | .UUID' | sed "s/\"//g"`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  echo ${existingServers}
}

function configureWebserver {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2953"
  elif [ "${DC}" == "GB3" ]; then
    ID="2603"
  elif [ "${DC}" == "IL1" ]; then
    ID="3034"
  elif [ "${DC}" == "UC1" ]; then
    ID="2815"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2233"
  else 
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi
    
  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"e7519c7c-d8e5-4bf2-86c1-57042e4d1480.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e7519c7c-d8e5-4bf2-86c1-57042e4d1480.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"e7519c7c-d8e5-4bf2-86c1-57042e4d1480.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"e7519c7c-d8e5-4bf2-86c1-57042e4d1480.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"e7519c7c-d8e5-4bf2-86c1-57042e4d1480.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"2d437c2e-b9ac-4c70-b9bf-2500061b86b5.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"283a14e1-0ed3-4b21-be67-24679636e592.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"9b6cae8f-98de-4751-b9bd-f8ebb3405c92.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"7e32a0e3-c687-4486-acc6-25e0d4524112.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e079a005-fc6f-453b-abf4-dd3494d767bb.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"25a13f15-24e1-411d-a023-89b94e78cc3f.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"25a13f15-24e1-411d-a023-89b94e78cc3f.Description\",\"Value\":\"${APP_NAME}\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure Lamp for ${1} on ${ACCT} has been queued. You will get an update every minute."

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
        echo "`date +"%c"`: Configure Lamp for ${1} on ${ACCT} has not finished after 20 minutes. Make sure to verify that the blueprint finishes! Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure Lamp for ${1} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

# Main
getAuth;
found=$(getWebservers)
declare -a "servers=($found)"
for i in "${servers[@]}"; do 
  # Verify if configure has already been run
  verifyConfigure=`/usr/bin/dig +short ${i}.ko.cld` 
  if [ -z ${verifyConfigure} ]; then
    configureWebserver ${i};
  else
    echo "`date +"%c"`: Configure Lamp has already been run on ${i}. Moving on..."
  fi
done
