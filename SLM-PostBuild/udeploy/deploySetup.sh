#!/bin/bash
## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
ADD_DC="${3}"

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"

#NOTE# Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Udeploy Variables
UD_ENDPOINT=""
UD_USER=""
UD_PASS=""

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
    NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    SERVICE_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    TECH_STACK=`jq -r .TechStack ./${SITE_ID}.json`
    GROUP=`jq -r .SiteGroup ./${SITE_ID}.json`
    LNAME=`jq -r '.Requestors[0] | .LastName' ./${SITE_ID}.json`
    EMAIL=`jq -r '.Requestors[0] | .Email' ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function step1 {
  if [[ "${1}" =~ "WEB" ]]; then
    srvType="Web"
    grpType="Web"
  elif [[ "${1}" =~ "WA" ]]; then
    srvType="Web and App"
    grpType="App"
  elif [[ "${1}" =~ "IIS" ]]; then
    srvType="IIS"
    grpType="IIS"
  elif [[ "${1}" =~ "MYSQL1" ]]; then
    srvType="MySQL (master)"
    grpType="DB"
  elif [[ "${1}" =~ "MSSQL1" ]]; then
    srvType="MsSQL (master)"
    grpType="DB"
  else
    return
  fi

  if [ "${ENV}" == "Production" ]; then
    ENV="Prod"
  fi
 
  resGroupID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/resource/resGroup" | jq -r '.[] | select(.path | contains("/'${SITE_ID}'/'${ENV}''${grpType}'")) | .id'`
  resGroup=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/resource/resGroup/static/${resGroupID}/resources" | jq -r '.[] | .name'`
  declare -a "resSrv=($resGroup)"
  for k in "${resSrv[@]}"; do
    if [ "${1}" == "${k}" ]; then
      echo "`date +"%c"`: Execution of Step 1 - Resource Groups on ${1} has already been run. Moving on..."
      return
    fi
  done

  serverJSON="{\"siteID\":\"${SITE_ID}\",\"devGroup\":\"${GROUP}\",\"serverType\":\"${srvType}\",\"env\":\"${ENV}\",\"siteType\":\"${SERVICE_TIER}\",\"resource\":\"${1}\",\"properties\":{\"siteID\":\"${SITE_ID}\",\"devGroup\":\"${GROUP}\",\"serverType\":\"${srvType}\",\"env\":\"${ENV}\",\"siteType\":\"${SERVICE_TIER}\",\"resource\":\"${1}\"},\"processId\":\"792aeb5b-1c68-426c-b680-c25d03009488\"}"
  run=`curl -s -u ${UD_USER}:${UD_PASS} -k -XPOST -H "Content-Type: application/json" -d "${serverJSON}" "https://${UD_ENDPOINT}/rest/process/request"`
  id=`echo "${run}" | jq -r '.id' 2> /dev/null`

  if [ "${id}" != "" ]; then
    state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id}" | jq -r '.trace | .state'`
    timer="0"
    while [ "${state}" != "CLOSED" ]; do
      echo "`date +"%c"`: Execution of Step 1 - Resource Groups on ${1} is: ${state}"
      sleep 15
      state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id}" | jq -r '.trace | .state'`
      timer=$(( timer + 1 ))
      if [ ${timer} == 20 ]; then
        break
      fi
    done
    result=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id}" | jq -r '.trace | .result'`
    echo "`date +"%c"`: Execution of Step 1 - Resource Groups on ${1} is: ${result}"    
  else
    echo "`date +"%c"`: Execution of Step 1 - Resource Groups on ${1} failed! Error: ${run}"
  fi

}

function step2 {
  if [ "${TECH_STACK}" == "Lamp" ]; then
    appType="Web"
    combined="No"
  elif [ "${TECH_STACK}" == "Java" ]; then
    appType="Tomcat"
    combined="Yes"
  elif [ "${TECH_STACK}" == "IIS" ]; then
    appType="IIS"
    combined="No"
  else
    combined="No"
  fi

  if [ "${ENV}" == "Production" ]; then
    ENV="Prod"
  fi

  appID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/all" | jq -r '.[] | select (.name=="'${SITE_ID}'") | .id'`
  getEnvironments=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullEnvironments" | jq '.[] | select(.name=="'${SITE_ID}'-'${ENV}'")'`
  if [ "${getEnvironments}" == "" ]; then
    siteJSON="{\"siteID\":\"${SITE_ID}\",\"devGroup\":\"${GROUP}\",\"appType\":\"${appType}\",\"siteType\":\"${SERVICE_TIER}\",\"combined\":\"${combined}\",\"env\":\"${ENV}\",\"resource\":\"9caea7ca-c3e1-400a-86c8-2080d7781b7e\",\"properties\":{\"siteID\":\"${SITE_ID}\",\"devGroup\":\"${GROUP}\",\"appType\":\"${appType}\",\"siteType\":\"${SERVICE_TIER}\",\"combined\":\"${combined}\",\"env\":\"${ENV}\",\"resource\":\"9caea7ca-c3e1-400a-86c8-2080d7781b7e\"},\"processId\":\"32726a29-1490-44cd-b84b-c99fc1ee65a0\"}"

    run2=`curl -s -u ${UD_USER}:${UD_PASS} -k -XPOST -H "Content-Type: application/json" -d "${siteJSON}" "https://${UD_ENDPOINT}/rest/process/request"`
    id2=`echo "${run2}" | jq -r '.id' 2> /dev/null`
    if [ "${id2}" != "" ]; then
      state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id2}" | jq -r '.trace | .state'`
      timer="0"
      while [ "${state}" != "CLOSED" ]; do
        echo "`date +"%c"`: Execution of Step 2 - Application Setup for ${SITE_ID} ${ENV} is: ${state}"
        sleep 15
        state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id2}" | jq -r '.trace | .state'`
        timer=$(( timer + 1 ))
        if [ ${timer} == 20 ]; then
          break
        fi
      done
      result=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id2}" | jq -r '.trace | .result'`
      echo "`date +"%c"`: Execution of Step 2 - Application Setup for ${SITE_ID} ${ENV} is: ${result}"
    else
      echo "`date +"%c"`: Execution of Step 2 - Application Setup for ${SITE_ID} ${ENV} has failed!  Error: ${run2}"
    fi
  else
    echo "`date +"%c"`: Execution of Step 2 - Application Setup for ${SITE_ID} ${ENV} has already been run. Moving on.."
  fi
}

function step3 {
  if [ "${TECH_STACK}" == "Lamp" ]; then
    appType="Web"
    component="${SITE_ID}-webComponent"
  elif [ "${TECH_STACK}" == "Java" ]; then
    appType="Tomcat"
    component="${SITE_ID}-tomcatComponent"
  elif [ "${TECH_STACK}" == "IIS" ]; then
    component="${SITE_ID}-IISComponent"
  fi

  if [ "${ENV}" == "Production" ]; then
    ENV="Prod"
  fi

  appID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/all" | jq -r '.[] | select (.name=="'${SITE_ID}'") | .id'`
  env=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullEnvironments" | jq -r '.[] | select(.name=="'${SITE_ID}'-'${ENV}'")'`
  envID=`echo ${env} | jq -r .id`
  compID=`echo ${env} | jq -r '. | .components[] | select(.name=="'${component}'") | .id'`
  mappingCheck=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/environment/${envID}/componentMappings/${compID}"`
  if [ "${mappingCheck}" == "[]" ]; then
    mappingJSON="{\"siteID\":\"${SITE_ID}\",\"devGroup\":\"${GROUP}\",\"appType\":\"${appType}\",\"siteType\":\"${SERVICE_TIER}\",\"env\":\"${ENV}\",\"resource\":\"9caea7ca-c3e1-400a-86c8-2080d7781b7e\",\"properties\":{\"siteID\":\"${SITE_ID}\",\"devGroup\":\"${GROUP}\",\"appType\":\"${appType}\",\"siteType\":\"${SERVICE_TIER}\",\"env\":\"${ENV}\",\"resource\":\"9caea7ca-c3e1-400a-86c8-2080d7781b7e\"},\"processId\":\"b9b03390-793a-4ce6-bf5f-233311a7b2b2\"}"

    run3=`curl -s -u ${UD_USER}:${UD_PASS} -k -XPOST -H "Content-Type: application/json" -d "${mappingJSON}" "https://${UD_ENDPOINT}/rest/process/request"`
    id3=`echo "${run3}" | jq -r '.id' 2> /dev/null`
    if [ "${id3}" != "" ]; then
      state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id3}" | jq -r '.trace | .state'`
      timer="0"
      while [ "${state}" != "CLOSED" ]; do
        echo "`date +"%c"`: Execution of Step 3 - Add Servers to App Environment for ${SITE_ID} ${ENV} is: ${state}"
        sleep 15
        state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id3}" | jq -r '.trace | .state'`
        timer=$(( timer + 1 ))
        if [ ${timer} == 20 ]; then
          break
        fi
      done
      result=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id3}" | jq -r '.trace | .result'`
      echo "`date +"%c"`: Execution of Step 3 - Add Servers to App Environment for ${SITE_ID} ${ENV} is: ${result}"
    else
      echo "`date +"%c"`: Execution of Step 3 - Add Servers to App Environment for ${SITE_ID} ${ENV} has failed!  Error: ${run3}"
    fi
  else
    echo "`date +"%c"`: Execution of Step 3 - Add Servers to App Environment for ${SITE_ID} ${ENV} has already been run. Moving on.."    
  fi
}

function step4 {
  if [[ "${TECH_STACK}" == "Lamp" || "${TECH_STACK}" == "Java" ]]; then
    dbType="MySQL (Linux)"
    component="${SITE_ID}-mysqlComponent"
  elif [ "${TECH_STACK}" == "IIS" ]; then
    # If Windows, get out of this function since no windows servers have a udeploy agent
    return 0
    dbType="MsSQL (Windows)"
    component="${SITE_ID}-mssqlComponent"
  fi

  if [[ "${ENV}" == "Production" || "${ENV}" == "Prod" ]]; then
    envFor4="Prod"
  elif [ "${ENV}" == "Test" ]; then
    envFor4="Test"
  fi

  appID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/all" | jq -r '.[] | select (.name=="'${SITE_ID}'") | .id'`
  env=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullEnvironments" | jq -r '.[] | select(.name=="'${SITE_ID}'-'${ENV}'")'`
  envID=`echo ${env} | jq -r .id`
  compID=`echo ${env} | jq -r '. | .components[] | select(.name=="'${component}'") | .id' 2> /dev/null`
  if [ "${compID}" == "" ]; then
    mappingCheck="[]"
  else
    mappingCheck=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/environment/${envID}/componentMappings/${compID}"`
  fi
  if [ "${mappingCheck}" == "[]" ]; then
    resGroupID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/resource/resGroup" | jq -r '.[] | select(.path | contains("/'${SITE_ID}'/ProdDB")) | .id'`
    master=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/resource/resGroup/static/${resGroupID}/resources" | jq -r '.[] | .name'`

    dbJSON="{\"siteID\":\"${SITE_ID}\",\"group\":\"${GROUP}\",\"siteType\":\"${SERVICE_TIER}\",\"dbType\":\"${dbType}\",\"environment\":\"${envFor4}\",\"prodMaster\":\"${master}\",\"resource\":\"9caea7ca-c3e1-400a-86c8-2080d7781b7e\",\"properties\":{\"siteID\":\"${SITE_ID}\",\"group\":\"${GROUP}\",\"siteType\":\"${SERVICE_TIER}\",\"dbType\":\"${dbType}\",\"environment\":\"${envFor4}\",\"prodMaster\":\"${master}\",\"resource\":\"9caea7ca-c3e1-400a-86c8-2080d7781b7e\"},\"processId\":\"095e68e4-0f18-4048-9fb4-e8ffcf436f38\"}"
  
    run4=`curl -s -u ${UD_USER}:${UD_PASS} -k -XPOST -H "Content-Type: application/json" -d "${dbJSON}" "https://${UD_ENDPOINT}/rest/process/request"`
    id4=`echo "${run4}" | jq -r '.id' 2> /dev/null`
    if [ "${id4}" != "" ]; then
      state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id4}" | jq -r '.trace | .state'`
      timer="0"
      while [ "${state}" != "CLOSED" ]; do
        echo "`date +"%c"`: Execution of Step 4 - DB for ${SITE_ID} ${ENV} is: ${state}"
        sleep 15
        state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id4}" | jq -r '.trace | .state'`
        timer=$(( timer + 1 ))
        if [ ${timer} == 20 ]; then
          break
        fi
      done
      result=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/process/request/${id4}" | jq -r '.trace | .result'`
      echo "`date +"%c"`: Execution of Step 4 - DB for ${SITE_ID} ${ENV} is: ${result}" 
    else
      echo "`date +"%c"`: Execution of Step 4 - DB for ${SITE_ID} ${ENV} has failed!  Error: ${run4}"
    fi
  else
    echo "`date +"%c"`: Execution of Step 4 - DB for ${SITE_ID} ${ENV}  has already been run. Moving on.."
  fi
}

function postSteps {
  appID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/all" | jq -r '.[] | select (.name=="'${SITE_ID}'") | .id'`
  getEnvironments=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullEnvironments"`
  envID=`echo ${getEnvironments} | jq -r '.[] | select (.name=="'${SITE_ID}'-'${ENV}'") | .id'`
  if [ "${ENV}" == "Test" ]; then
    color="#87cefa"
  elif [ "${ENV}" == "Prod" ]; then
    setGates=`curl -s -u ${UD_USER}:${UD_PASS} -k -X PUT -H "Content-Type: application/json" -d "[{\"environmentId\":\"${envID}\",\"conditions\":[[\"Live in Test\"],[\"Live in Prod\"]]}]" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/environmentConditions"`
    color="#dda0dd"
  else 
    color="#90ee90"
  fi
  setColor=`curl -s -u ${UD_USER}:${UD_PASS} -k -X PUT -H "Content-Type: application/json" -d "{\"name\":\"${SITE_ID}-${ENV}\",\"description\":\"\",\"requireApprovals\":\"false\",\"exemptProcesses\":\"\",\"lockSnapshots\":\"false\",\"color\":\"${color}\",\"inheritSystemCleanup\":\"true\",\"applicationId\":\"${appID}\",\"existingId\":\"${envID}\"}" "https://${UD_ENDPOINT}/rest/deploy/environment"`
}

function deploy {
  if [[ "${TECH_STACK}" == "Lamp" || "${TECH_STACK}" == "Java" ]]; then
    component="${SITE_ID}-webComponent"
    deployName="Web Deploy"
  elif [ "${TECH_STACK}" == "IIS" ]; then
    component="${SITE_ID}-IISComponent"
    deployName="IIS Deploy"
  fi

  appID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/all" | jq -r '.[] | select (.name=="'${SITE_ID}'") | .id'`
  env=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullEnvironments" | jq -r '.[] | select(.name=="'${SITE_ID}'-'${ENV}'")'`
  envID=`echo ${env} | jq -r .id`
  compID=`echo ${env} | jq -r '. | .components[] | select(.name=="'${component}'") | .id'`
  appProcessID=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullProcesses" | jq -r '.[] | select(.name=="'${deployName}'") | .id'`

  if [ "${ADD_DC}" == "" ]; then
    version1=`curl -s -u ${UD_USER}:${UD_PASS} -k -X PUT -H "Content-Type: application/json" -d "{\"properties\":{\"revision\":\"1\"}}" "https://${UD_ENDPOINT}/rest/deploy/component/${compID}/integrate"`
    deployVersion1=`curl -s -u ${UD_USER}:${UD_PASS} -k -X PUT -H "Content-Type: application/json" -d "{\"onlyChanged\":\"true\",\"applicationProcessId\":\"${appProcessID}\",\"snapshotId\":\"\",\"scheduleCheckbox\":false,\"description\":\"Deploy during Site Launch\",\"properties\":{},\"versions\":[{\"versionSelector\":\"version/1\",\"componentId\":\"${compID}\"}],\"applicationId\":\"${appID}\",\"environmentId\":\"${envID}\"}" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/runProcess"`
    verify=`echo ${deployVersion1} | jq -r '.requestId' 2> /dev/null`
    if [ "${verify}" != "" ]; then
      sleep 15
      state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/applicationProcessRequest/${verify}"` 
      result=`echo ${state} | jq -r .result`
      if [ "${result}" == "FAULTED" ]; then
        error=`echo ${state} | jq -r .error`
        echo "`date +"%c"`: Version 1 deploy has failed with the error: ${error}"
      else
        echo "`date +"%c"`: Version 1 has been deployed to ${ENV}"
      fi
    else
      echo "`date +"%c"`: Version 1 has not been deployed to ${ENV}! You should login and check why"
    fi
  else
    currentVersion=`curl -s -u admin:Qu@s! -k -XGET "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/fullEnvironments" | jq -r '.[] | select(.name=="'${SITE_ID}'-'${ENV}'") | .components[] | select(.name=="'${SITE_ID}'-webComponent") | .versions[] | .name'`
    deployCurrentVersion=`curl -s -u ${UD_USER}:${UD_PASS} -k -X PUT -H "Content-Type: application/json" -d "{\"onlyChanged\":\"true\",\"applicationProcessId\":\"${appProcessID}\",\"snapshotId\":\"\",\"scheduleCheckbox\":false,\"description\":\"Adding code to new datacenter servers\",\"properties\":{},\"versions\":[{\"versionSelector\":\"${currentVersion}\",\"componentId\":\"${compID}\"}],\"applicationId\":\"${appID}\",\"environmentId\":\"${envID}\"}" "https://${UD_ENDPOINT}/rest/deploy/application/${appID}/runProcess"`
    verify=`echo ${deployCurrentVersion} | jq -r '.requestId' 2> /dev/null`
    if [ "${verify}" != "" ]; then
      sleep 15
      state=`curl -s -u ${UD_USER}:${UD_PASS} -k -XGET -H "Content-Type: application/json" "https://${UD_ENDPOINT}/rest/deploy/applicationProcessRequest/${verify}"`
      result=`echo ${state} | jq -r .result`
      if [ "${result}" == "FAULTED" ]; then
        error=`echo ${state} | jq -r .error`
        echo "`date +"%c"`: Version ${currentVersion} deploy has failed with the error: ${error}"
      else
        echo "`date +"%c"`: Version ${currentVersion} has been deployed to ${ENV}"
      fi
    else
      echo "`date +"%c"`: Version ${currentVersion} has not been deployed to ${ENV}! You should login and check why"
    fi
  fi
}

getAuth;
getSiteInfo;
hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${DC}' Hardware") | .UUID'`
getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
existingServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
declare -a "servers=($existingServers)"
for i in "${servers[@]}"; do
  step1 ${i};
done
step2;
step3;
if [ "${DBAAS}" == "false" ]; then
  step4;
fi
postSteps;
deploy;
#cleanup
rm ./${SITE_ID}.json
