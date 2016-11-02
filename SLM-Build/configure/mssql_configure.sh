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
upperEnv=`echo "${ENV}" | awk '{print toupper($0)}'`
if [ "${upperEnv}" == "PRODUCTION" ]; then
  upperEnv="PROD"
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

function getMSSQLServers {
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - DB") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  echo ${existingServers}
}

function configureBasic {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2947"
    Custom_ID="4533"
  elif [ "${DC}" == "GB3" ]; then
    ID="2597"
    Custom_ID="4085"
  elif [ "${DC}" == "IL1" ]; then
    ID="3028"
    Custom_ID="4504"
  elif [ "${DC}" == "UC1" ]; then
    ID="2809"
    Custom_ID="4367"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2227"
    Custom_ID="3656"
  else 
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
    exit 1
  fi
    
  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"e50b2eb4-7bd8-4e59-bcbb-9866e585c284.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e50b2eb4-7bd8-4e59-bcbb-9866e585c284.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"e50b2eb4-7bd8-4e59-bcbb-9866e585c284.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"e50b2eb4-7bd8-4e59-bcbb-9866e585c284.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"e50b2eb4-7bd8-4e59-bcbb-9866e585c284.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Install.Disk\",\"Value\":\"E\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Version\",\"Value\":\"2014\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Edition\",\"Value\":\"Standard\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.InstanceName\",\"Value\":\"KO${SITE_ID}MS${upperEnv}\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Analysis\",\"Value\":\"No\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Reporting\",\"Value\":\"No\"},{\"Name\":\"bc7257ef-bbaa-4018-8cc3-bf540c1255d9.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"0dad39a6-89b1-43ad-a034-13cfc9c702a2.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"0dad39a6-89b1-43ad-a034-13cfc9c702a2.ProductCode\",\"Value\":\"SOFT-MSSQLSTD2014-CPU\"}]}"

  echo "${configureJSON}"
  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure MSSQL Basic for ${1} on ${ACCT} has been queued. You will get an update every minute."

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
        echo "`date +"%c"`: Configure MSSQL Basic for ${1} on ${ACCT} has not finished after 30 minutes. Make sure to verify that the blueprint finishes. Moving on..."
        break
      fi
    done

  #Ensure MSSQL configure is finished before moving on
  mssqlCheck="1"
  while [ ${mssqlCheck} -ne 8 ]; do
    echo "`date +"%c"`: MSSQL HPSA job still running on ${1}, checking again in 2 minutes.."
    sleep 120
    mssqlCheck=`nc -z -v ${1} 49152-65535 2>&1 | grep succeeded | wc -l`
  done

    # Once configure finished, run customize
    if [ ${configurePercent} -eq 100 ]; then
      getAuth;
      customizeJSON="{\"ID\":\"${Custom_ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"7808cacd-3fd9-4268-90ac-4160587f4f2c.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"ff6721a4-b6cf-4f3c-8f1a-3360d1a950d9.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"71dc3fb9-c907-432b-9bc0-cf4729fafb6c.TaskServer\",\"Value\":\"${1}\"}]}"

      customize=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${customizeJSON}"`
      echo "${customize}"
      requestID=`echo ${customize} | jq -r '.RequestID'`
      if [ ${requestID} -ne 0 ]; then
        echo "`date +"%c"`: Customize MSSQL for ${1} on ${ACCT} has been queued. You will get an update every minute, but please be patient!  This process could take up to an hour."

        # Don't move till customize completed
        customizePercent="0"
        timer="0"
        while [ ${customizePercent} -ne 100 ]; do
          sleep 60
          getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          customizePercent=`echo ${getStatus} | jq -r .PercentComplete`
          currentStatus=`echo ${getStatus} | jq -r .CurrentStatus`
          # The cookie timesout after like 15 minutes.. As this takes longer than 15 minutes, it must be refreshed
          if [ ${customizePercent} -eq 0 ]; then
	    getAuth;
            getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            customizePercent=`echo ${getStatus} | jq -r .PercentComplete`
          fi
          echo "`date +"%c"`: Customize ${1} for ${ACCT} is ${customizePercent}% complete..."
          timer=$(( timer + 1 ))
          if [ ${timer} -eq 30 ]; then
            echo "`date +"%c"`: Customize MSSQL for ${1} ${ACCT} has not finished after 30 minutes. Make sure to verify that the blueprint finishes. Moving on..."
            break
          fi
          if [ "${currentStatus}" == "Failed" ]; then
            echo "`date +"%c"`: Customize MSSQL for ${1} on ${ACCT} has failed! You may be able to resume it in the control console. Moving on..."
            break
          fi
        done
      else
         echo "`date +"%c"`: Customize MSSQL for ${1} on ${ACCT} has failed, go figure out why! Moving on..."
      fi
    fi
  else
    echo "`date +"%c"`: Configure MSSQL Basic for ${1} on ${ACCT} has failed! Bailing.."
    exit 1
  fi

}

function configureStandard {
  # Set BP ID
  if [ "${DC}" == "VA1" ]; then
    ID="2963"
    Custom_ID="3470"
  elif [ "${DC}" == "GB3" ]; then
    ID="2613"
    Custom_ID="3048"
  elif [ "${DC}" == "IL1" ]; then
    ID="3043"
    Custom_ID="3490"
  elif [ "${DC}" == "UC1" ]; then
    ID="2825"
    Custom_ID="3292"
  elif [ "${DC}" == "SG1"  ]; then
    ID="2243"
    Custom_ID="2668"
  else
    echo "No Datacenter assigned! This shouldn't have happened!! Bailing..."
  fi

  configureJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"b11cb70d-cb8e-426c-8dcf-4a7545c3bbf2.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"b11cb70d-cb8e-426c-8dcf-4a7545c3bbf2.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"b11cb70d-cb8e-426c-8dcf-4a7545c3bbf2.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"b11cb70d-cb8e-426c-8dcf-4a7545c3bbf2.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"b11cb70d-cb8e-426c-8dcf-4a7545c3bbf2.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"35582e41-2b9c-4bfa-b2bd-71140e16cf00.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"35582e41-2b9c-4bfa-b2bd-71140e16cf00.SiteID\",\"Value\":\"${SITE_ID}\"},{\"Name\":\"35582e41-2b9c-4bfa-b2bd-71140e16cf00.Envi\",\"Value\":\"${lowerEnv}\"},{\"Name\":\"35582e41-2b9c-4bfa-b2bd-71140e16cf00.Ref\",\"Value\":\"${REF_ARCH}\"},{\"Name\":\"35582e41-2b9c-4bfa-b2bd-71140e16cf00.ServiceTier\",\"Value\":\"${SERV_TIER}\"},{\"Name\":\"2c1b72a2-0a58-48c6-b64f-d6b87fd671c9.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"2c1b72a2-0a58-48c6-b64f-d6b87fd671c9.Description\",\"Value\":\"${APP_NAME}\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Install.Disk\",\"Value\":\"E\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Version\",\"Value\":\"2014\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Edition\",\"Value\":\"Standard\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.InstanceName\",\"Value\":\"KO${SITE_ID}MS${upperEnv}\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Analysis\",\"Value\":\"No\"},{\"Name\":\"5cdd4444-d286-45e4-befa-e51b7dd91c31.CTS.MSSQL.Reporting\",\"Value\":\"No\"},{\"Name\":\"bc7257ef-bbaa-4018-8cc3-bf540c1255d9.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"0dad39a6-89b1-43ad-a034-13cfc9c702a2.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"0dad39a6-89b1-43ad-a034-13cfc9c702a2.ProductCode\",\"Value\":\"SOFT-MSSQLSTD2014-CPU\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.CTS.MSSQL.Install.Disk\",\"Value\":\"E\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.CTS.MSSQL.Version\",\"Value\":\"2014\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.CTS.MSSQL.Edition\",\"Value\":\"Standard\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.CTS.MSSQL.InstanceName\",\"Value\":\"KO${SITE_ID}MS${upperEnv}\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.CTS.MSSQL.Analysis\",\"Value\":\"No\"},{\"Name\":\"07f0c9a8-e430-433d-9bb1-4e7b9a22a8aa.CTS.MSSQL.Reporting\",\"Value\":\"No\"},{\"Name\":\"2d3f4b87-3f31-4a70-a1ac-4c7d6d70d7a0.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"8757ce0d-d300-480b-bad0-f909cadaa90b.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"8757ce0d-d300-480b-bad0-f909cadaa90b.ProductCode\",\"Value\":\"SOFT-MSSQLSTD2014-CPU\"}]}"

  configure=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${configureJSON}"`
  echo "${configure}"
  requestID=`echo ${configure} | jq -r '.RequestID'`
  if [ ${requestID} -ne 0 ]; then
    echo "`date +"%c"`: Configure MSSQL for ${1} and ${2} on ${ACCT} have been queued. You will get an update every minute, but please be patient!  This process could take up to an hour."

    # Don't move till configure completed
    getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
    configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
    timer="0"
    while [ ${configurePercent} -ne 100 ]; do
      sleep 60
      getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
      configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      currentStatus=`echo ${getStatus} | jq -r .CurrentStatus`
      # The cookie timesout after like 15 minutes.. As this takes longer than 15 minutes, it must be refreshed
      if [ ${configurePercent} -eq 0 ]; then
	getAuth;
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
      fi
      echo "`date +"%c"`: Configure ${1} and ${2} for ${ACCT} is ${configurePercent}% complete..."
      timer=$(( timer + 1 ))
      if [ ${timer} -eq 60 ]; then
        echo "`date +"%c"`: Configure MSSQL for ${1} and ${2} on ${ACCT} have not finished after 60 minutes. Make sure to verify that the blueprint finishes. Moving on..."
        break
      fi
      if [ "${currentStatus}" == "Failed" ]; then
        echo "`date +"%c"`: Configure MSSQL for ${1} and ${2} on ${ACCT} has failed! You may be able to resume it in the control console. Moving on..."
        break
      fi
    done

    #Ensure MSSQL configure is finished before moving on
    mssqlCheck1="1"
    mssqlCheck2="2"
    while [[ ${mssqlCheck1} -ne 8 && ${mssqlCheck2} -ne 8 ]]; do
      echo "`date +"%c"`: MSSQL HPSA job still running on ${1} and ${2}, checking again in 2 minutes.."
      sleep 120
      mssqlCheck1=`nc -z -v ${1} 49152-65535 2>&1 | grep succeeded | wc -l`
      mssqlCheck1=`nc -z -v ${2} 49152-65535 2>&1 | grep succeeded | wc -l`
    done

    # Now if configure finished, run customize
    if [ ${configurePercent} -eq 100 ]; then
      # re-login just in case
      getAuth;
      customizeJSON="{\"ID\":\"${Custom_ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"ee39d398-356b-4984-833d-7904cbe2a59a.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"78864c1e-0f4b-41a8-97db-73cc2ba29c9c.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"db92a999-f4d6-4e68-b77f-d2ff385f2997.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"d06ed6a0-f3eb-4069-b42c-fec2bd1a129e.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"b09b9cd2-f385-405e-85ae-ea1584803a63.TaskServer\",\"Value\":\"${2}\"},{\"Name\":\"e364ef0c-dd98-474f-b496-0d9f5de825cb.TaskServer\",\"Value\":\"${2}\"}]}"

      customize=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${customizeJSON}"`
      echo "${customize}"
      requestID=`echo ${customize} | jq -r '.RequestID'`
      if [ ${requestID} -ne 0 ]; then
        echo "`date +"%c"`: Customize MSSQL for ${1} and ${2} on ${ACCT} have been queued. You will get an update every minute, but please be patient!  This process could take up to an hour."

        # Don't move till customize completed
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
        timer="0"
        while [ ${configurePercent} -ne 100 ]; do
          sleep 60
          getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
          currentStatus=`echo ${getStatus} | jq -r .CurrentStatus`
          # The cookie timesout after like 15 minutes.. As this takes longer than 15 minutes, it must be refreshed
          if [ ${configurePercent} -eq 0 ]; then
	    getAuth;
            getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            configurePercent=`echo ${getStatus} | jq -r .PercentComplete`
          fi
          echo "`date +"%c"`: Configure ${1} and ${2} for ${ACCT} is ${configurePercent}% complete..."
          timer=$(( timer + 1 ))
          if [ ${timer} -eq 60 ]; then
            echo "`date +"%c"`: Configure MSSQL for ${1} and ${2} on ${ACCT} have not finished after 60 minutes. Make sure to verify that the blueprint finishes. Moving on..."
            break
          fi
          if [ "${currentStatus}" == "Failed" ]; then
            echo "`date +"%c"`: Customize MSSQL for ${1} and ${2} on ${ACCT} has failed! You may be able to resume it in the control console. Moving on..."
            break
          fi
        done
      else
         echo "`date +"%c"`: Customize MSSQL for ${1} and ${2} on ${ACCT} has failed, go figure out why! Moving on..."
      fi
    fi
  else
    echo "`date +"%c"`: Configure MSSQL for ${1} and ${2} on ${ACCT} has failed, go figure out why! Moving on..."
    break
  fi

}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

# Main
getAuth;
found=$(getMSSQLServers)
declare -a "servers=($found)"
if [ "${REF_ARCH}" == "Basic" ]; then
  # Verify if configure has already been run
  middleware=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware' ./${SITE_ID}.json`
  verifyDNS=`/usr/bin/dig +short ${servers[0]}.ko.cld`
  if [ "${middleware}" != "Completed" ]; then
    if [ ! -z ${verifyDNS} ]; then
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
      echo "`date +"%c"`: ${servers[0]} has not joined the KO.CLD domain.  Correct this and run configure again."
    fi
  else
    echo "`date +"%c"`: Configure MSSQL Basic has already been run on ${servers[0]}. Moving on..."
  fi
elif [ "${REF_ARCH}" == "Standard" ]; then
  middleware1=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware' ./${SITE_ID}.json`
  middleware2=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[1]}'") | .Middleware' ./${SITE_ID}.json`
  verifyDNS1=`/usr/bin/dig +short ${servers[0]}.ko.cld`
  verifyDNS2=`/usr/bin/dig +short ${servers[1]}.ko.cld`
  if [[ "${middleware1}" != "Completed" && "${middleware2}" != "Completed" && ! -z ${verifyDNS1} && ! -z ${verifyDNS2} ]]; then
    getAuth;
    configureStandard ${servers[0]} ${servers[1]};
    if [ ${?} -ne 1 ]; then
      # Update JSON marking server middleware completed
      newJSON1=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[0]}'") | .Middleware) |= "Completed"' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${newJSON1} > ./${SITE_ID}.json
      newJSON2=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${servers[1]}'") | .Middleware) |= "Completed"' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${newJSON2} > ./${SITE_ID}.json
      updateOrchestrate;
    fi
  else
    echo "`date +"%c"`: Configure MSSQL Standard has already been run on: ${servers[0]} and ${servers[1]}. Moving on..."
  fi
else
  echo "No Reference Architecture Found! This shouldn't have happened!! Bailing..."
  exit 1
fi
