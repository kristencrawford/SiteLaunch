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
  # Check webserver total before creating any servers
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - FS") | .UUID' | sed "s/\"//g"`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  echo ${existingServers}
}

function configureFileserver {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="3174"
  elif [ "${DC}" == "GB3" ]; then
    ID="2801"
  elif [ "${DC}" == "IL1" ]; then
    ID="3235"
  elif [ "${DC}" == "UC1" ]; then
    ID="3026"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2422"
  else 
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi
    
  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"cae0d262-0dc2-463c-b678-bb068c304f80.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"cae0d262-0dc2-463c-b678-bb068c304f80.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"cae0d262-0dc2-463c-b678-bb068c304f80.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"cae0d262-0dc2-463c-b678-bb068c304f80.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"a0cf8241-6f83-4c75-84b9-79dbccf70208.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"a2cf7fa6-bd63-4f8d-8779-c6e73555fe68.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"ca517de3-9efd-4fa6-b6f3-a7be128aa5e5.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"236d9774-e93f-42b4-a727-78b0dd3da3a9.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"53aa3a9b-1bbd-41ee-9431-eb7daf7a98f2.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"12d050be-6fdf-4bcc-b8f7-aafb04d817b7.TaskServer\",\"Value\":\"${1}\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure Fileserver for ${1} on ${ACCT} has been queued. You will get an update every minute."

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
        echo "`date +"%c"`: Configure Fileserver for ${1} on ${ACCT} has not finished after 20 minutes. Make sure to verify that the blueprint finishes! Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure Fileserver for ${1} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

function configureNFSClient {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="3182"
  elif [ "${DC}" == "GB3" ]; then
    ID="2808"
  elif [ "${DC}" == "IL1" ]; then
    ID="3244"
  elif [ "${DC}" == "UC1" ]; then
    ID="3036"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2430"
  else
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi

  nfsJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"e440b3e4-42c9-499b-b4ae-96d69515efed.TaskServer\",\"Value\":\"${1}\"}]}"

  nfsclient=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${nfsJSON}"`
  requestID=`echo ${nfsclient} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: NFS Client setup on ${1} for ${ACCT} has been queued. You will get an update every minute."

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
      echo "`date +"%c"`: NFS Client setup on ${1} for ${ACCT} is ${configurePercent}% complete..."
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 20 ]; then
        echo "`date +"%c"`: NFS Client setup on ${1} for ${ACCT} has not finished after 20 minutes. Make sure to verify that the blueprint finishes! Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: NFS Client setup on ${1} for ${ACCT} has failed! Bailing.."
    exit 1
  fi


}

# Main
getAuth;
fileServer=$(getServer)
verifyConfigure=`/usr/bin/dig +short ${fileServer}.ko.cld`
if [ -z ${verifyConfigure} ]; then
  configureFileserver ${fileServer};
  # After configure Fileserver completes, run nfs client on all webservers
  found=$(getServer Web)
  declare -a "webServers=($found)"
  for i in "${webServers[@]}"; do
    configureNFSClient ${i};
  done
else
  echo "`date +"%c"`: Configure Fileserver has already been run on ${fileServer}. Moving on..."
fi
