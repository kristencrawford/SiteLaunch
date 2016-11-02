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
if [ "${ENV}" == "Test" ]; then
  REF_ARCH="Basic"
fi
passwd=`mkpasswd -l 20 -d 3 -C 5 -s 0`

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

function getMysqlServers {
  # Check mysql total before cconfiguring any servers
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - DB") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  echo ${existingServers}
}

function configureBasic {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2867"
  elif [ "${DC}" == "GB3" ]; then
    ID="2521"
  elif [ "${DC}" == "IL1" ]; then
    ID="2950"
  elif [ "${DC}" == "UC1" ]; then
    ID="2730"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2149"
  else 
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi
    
  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"2ad3e5c6-0032-45fb-bf57-0c79986ffe13.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"2ad3e5c6-0032-45fb-bf57-0c79986ffe13.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"2ad3e5c6-0032-45fb-bf57-0c79986ffe13.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"2ad3e5c6-0032-45fb-bf57-0c79986ffe13.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"2ad3e5c6-0032-45fb-bf57-0c79986ffe13.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"a93300e7-9534-49e4-a1da-7e09755cb4d4.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"1e5eb573-9cbc-40b9-8523-975ff43dd807.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"a7423c4a-debe-4bff-a670-82af9282c1c3.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"8e80334a-ec91-44bc-aae9-242141cb9351.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"6ff8bd41-f72e-4aae-848b-11df426b8f0e.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"2265eb07-2af4-4438-a2fc-0a97edcbbb93.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e04cd551-92a7-45af-a079-27cc87b38c45.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e04cd551-92a7-45af-a079-27cc87b38c45.Description\",\"Value\":\"${APP_NAME}\"},{\"Name\":\"9539732c-5bae-4b1c-9f81-48829c9d591c.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"9539732c-5bae-4b1c-9f81-48829c9d591c.CTS.MYSQL.Version\",\"Value\":\"v5.6\"},{\"Name\":\"29e6a44c-c852-4014-883e-5174926fd0ce.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"d6800e14-49bd-426b-961e-2edca2846889.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"7aefc8b3-242a-4f13-b0e6-429757a25798.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"c9146003-6654-4c43-9cf1-ba20ea9678e6.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"6751fd62-f208-4aca-9928-f79227d9c1fa.TaskServer\",\"Value\":\"${1}\"}]}"
  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure MYSQL for ${1} on ${ACCT} has been queued. You will get an update every 3 minutes, but please be patient!  This process could take up to an hour."

    # Don't move till configure completed
    getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
    configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
    timer="0"
    while [ ${configurePercent} -ne 100 ]; do
      sleep 180
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
      if [ ${timer} -eq 20 ]; then
        echo "`date +"%c"`: Configure MYSQL for ${1} on ${ACCT} has not finished after 60 minutes. Make sure to verify that the blueprint finishes. Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure MYSQL for ${1} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

function configureStandard {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2868"
  elif [ "${DC}" == "GB3" ]; then
    ID="2522"
  elif [ "${DC}" == "IL1" ]; then
    ID="2951"
  elif [ "${DC}" == "UC1" ]; then
    ID="2732"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2150"
  else
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi

  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"b009f6eb-888e-41ee-a096-c4e09b028385.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"b009f6eb-888e-41ee-a096-c4e09b028385.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"b009f6eb-888e-41ee-a096-c4e09b028385.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"b009f6eb-888e-41ee-a096-c4e09b028385.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"b009f6eb-888e-41ee-a096-c4e09b028385.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"e73e5377-3667-4672-a068-31549c4287c7.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"c066f973-d2ca-4f38-beb2-c0c8b27f15dc.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"64659fb2-3c88-43b8-a2b3-6909cb538ca6.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"01d7b06d-bae3-4180-93e8-37a997a159d2.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"37e408b1-75d8-4ffe-8729-5dbb0df518f6.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"40bcebc5-a8c5-4337-9687-23ca79b699c5.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"40bcebc5-a8c5-4337-9687-23ca79b699c5.NewPW\",\"Value\":\"${passwd}\"},{\"Name\":\"520758c9-25fa-45e6-bb18-ab3bb8cb9511.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"520758c9-25fa-45e6-bb18-ab3bb8cb9511.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"520758c9-25fa-45e6-bb18-ab3bb8cb9511.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"520758c9-25fa-45e6-bb18-ab3bb8cb9511.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"520758c9-25fa-45e6-bb18-ab3bb8cb9511.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"7785ed54-b382-4b24-ae95-1ea3c3114c8e.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"b9ee65a3-36f9-4ea5-8acc-a2d519a16eee.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"09857729-2591-4fa6-b496-7d523647a690.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"ce8d0efc-dd5f-4d6c-b65b-3fb03e1355d6.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"ca5fc332-fb12-4b3b-9209-ae1c9bfc174f.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"6b8f5b46-e92f-4409-8930-0502e211a8b8.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"6b8f5b46-e92f-4409-8930-0502e211a8b8.NewPW\",\"Value\":\"${passwd}\"},{\"Name\":\"df2ca714-2eac-470f-bc3f-41c81f1ef256.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"94d647a6-7580-4a77-acb0-67c176c7ff80.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"8f48dfb7-ff48-457a-852a-8795acaad0ed.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"8111089f-121b-4af2-b4ae-032f7c49d939.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"8111089f-121b-4af2-b4ae-032f7c49d939.Description\",\"Value\":\"${APP_NAME}\"},{\"Name\":\"243fb738-d64b-409b-bb75-1690510390d2.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"243fb738-d64b-409b-bb75-1690510390d2.CTS.MYSQL.Version\",\"Value\":\"v5.6\"},{\"Name\":\"8bada90b-e53a-49b2-83ab-23142cbaa68e.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"293bab55-07bc-482f-88a9-1b5cf8bdc919.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"b585ff8d-e757-4208-be3a-58b5cccdec06.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"9878bf6f-98a3-462c-a875-446253ed4aa8.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"be5a7af8-56a5-4627-9573-f4fea3ddaff6.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"af86fd08-df9d-4c94-8563-dd431161db64.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"af86fd08-df9d-4c94-8563-dd431161db64.CTS.MYSQL.Version\",\"Value\":\"v5.6\"},{\"Name\":\"6db294bd-11f9-47c2-ada4-73ab0eca1cc0.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"11f7ba45-7750-44fc-91d9-24fdd7ddc76a.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"e5375c06-b9aa-46bf-a599-6a49db12cf9d.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"c52da7a1-d93d-4525-a43a-4e1ed4421c4a.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"4fde02f7-bcbf-4e08-9ec9-2c5769297c33.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"72d65fdb-0b70-465e-8b6c-579e02feccb4.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"72d65fdb-0b70-465e-8b6c-579e02feccb4.CTS.MASTER.PASSWORD\",\"Value\":\"${passwd}\"},{\"Name\":\"72d65fdb-0b70-465e-8b6c-579e02feccb4.CTS.SLAVE.SERVER\",\"Value\":\"${2}\"},{\"Name\":\"72d65fdb-0b70-465e-8b6c-579e02feccb4.CTS.SLAVE.PASSWORD\",\"Value\":\"${passwd}\"},{\"Name\":\"df84bd20-ea07-4987-b219-b046d743406e.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e69b7c4d-4aab-4b8a-bcf9-56c9e8fbf9bb.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"7aca8aa7-a46b-485d-a326-3799537d5b05.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"16a88682-1d4d-415d-9aa3-d7e4fea8c3ae.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"ff2a1911-36af-4e6e-9e2b-bf4916ce472c.TaskServer\",\"Value\":\"${2}\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure MYSQL for ${1} and ${2} on ${ACCT} have been queued. You will get an update every 3 minutes, but please be patient!  This process could take up to 2 hours."

    # Don't move till configure completed
    getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
    configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
    timer="0"
    while [ ${configurePercent} -ne 100 ]; do
      sleep 180
      getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
      configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      # The cookie timesout after like 15 minutes.. As this takes longer than 15 minutes, it must be refreshed
      if [ ${configurePercent} -eq 0 ]; then
	getAuth;
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      fi
      echo "`date +"%c"`: Configure ${1} and ${2} for ${ACCT} are ${configurePercent}% complete..."
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 40 ]; then
        echo "`date +"%c"`: Configure MYSQL for ${1} and ${2} on ${ACCT} have not finished after 120 minutes. Make sure to verify that the blueprint finishes. Moving on..."
        break
      fi
    done
  else
    echo "`date +"%c"`: Configure MYSQL for ${1} and ${2} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}


# Main
getAuth;
found=$(getMysqlServers)
declare -a "servers=($found)"
if [ "${REF_ARCH}" == "Basic" ]; then
  # Verify if configure has already been run
  verifyConfigure=`/usr/bin/dig +short ${servers[0]}.ko.cld`
  if [ -z ${verifyConfigure} ]; then
    getAuth;
    configureBasic ${servers[0]};
  else
    echo "`date +"%c"`: Configure-Basic-DB has already been run on ${servers[0]}. Moving on..."
  fi
elif [ "${REF_ARCH}" == "Standard" ]; then
  verifyMaster=`/usr/bin/dig +short ${servers[0]}.ko.cld`
  verifySlave=`/usr/bin/dig +short ${servers[1]}.ko.cld`
  if [[ -z ${verifyMaster} && -z ${verifySlave} ]]; then
    getAuth;
    configureStandard ${servers[0]} ${servers[1]};
  else
    echo "`date +"%c"`: Configure-Standard-DB has already been run on Master: ${servers[0]} and Slave: ${servers[1]}. Moving on..."
  fi
else
  echo "No Reference Architecture Found! This shouldn't have happened!! Bailing..."
  exit 1
fi
