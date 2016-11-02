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
if [ ${ACCT} == "" ]; then
  echo "`date +"%c"`: The ${ENV} Alias is missing from ${SITE_ID}.json. Filserver build cannot be completed without this information. Please ensure create subaccount finished successfully and updated the site's json."
  exit 1
fi

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"
ACCT_V1AUTH="{ \"APIKey\": \"${API_KEY}\", \"Password\": \"${API_PSSWD}\" }"

#Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
  getAccountAuth=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "acctCookies.txt" -d "${ACCT_V1AUTH}"`
}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

function getFileServers {
  # Check fileserver total before creating any servers
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - FS") | .UUID' | sed "s/\"//g"`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq '.Servers | length'`
  echo ${existingServers}
}

function createFileServer {
  # Create build fileserver json
  getGroups=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}"`
  groupID=`echo ${getGroups} | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - FS") | .UUID' | sed "s/\"//g"`
  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  networkID=`echo ${getNetworks} | jq -r '.[] | select(.name=="'${SITE_ID}' - '${ENV}' - Web") | .id'`
  if [[ ${groupID} != "" && ${networkID} != "" ]]; then
    fsJSON="{\"name\":\"fs\",\"description\":\"fileserver\",\"groupId\":\"${groupID}\",\"sourceServerId\":\"VA1TCCCTMPL02\",\"isManagedOS\":false,\"primaryDns\":\"172.17.1.26\",\"networkId\":\"${networkID}\",\"cpu\":1,\"memoryGB\":8,\"type\":\"standard\",\"storageType\":\"standard\",\"Packages\":[{\"packageID\":\"24485861-e860-48bd-83c2-2bacb167f3ec\"}]}"

    # Build fileserver
    build=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "${fsJSON}"`
    requestID=`echo ${build} | jq '.links[] | select(.rel=="status") | .id' | sed "s/\"//g" | awk -F- '{print $2}'`

    if [ ${requestID} -ne 0 ]; then
      echo "`date +"%c"`: Build fileserver on ${ACCT} has been queued. You will get an update every 30 seconds."

      # Don't move to make managed until server build is completed
      buildStatus="0"
      timer="0"
      while [ ${buildStatus} -ne 100 ]; do
        sleep 30
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        buildStatus=`echo ${getStatus} | jq -r .PercentComplete`
        if [ ${buildStatus} -eq 0 ]; then
  	  getAuth;
          getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          buildStatus=`echo ${getStatus} | jq -r .PercentComplete`
        fi
        serverName=`echo ${getStatus} | jq -r .Servers | grep FS | sed "s/\"//g" | sed "s/\ //g" | sed "s/\,//g"`
        echo "`date +"%c"`: Server ${serverName} for ${ACCT} build is ${buildStatus}% complete..."
        timer=$(( timer + 1 ))
        if [ ${timer} -eq 20 ]; then
          break
        fi
      done

      # Update JSON
      updateJSONfs ${serverName};

      # Ensure Server is ready for make managed and get IP for later push to slimdb
      ipAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${serverName}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
      while [ "${ipAddress}" == "" ]; do
        sleep 5
        ipAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${serverName}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
      done

      # Once server build is at 100% completed, run make managed and move on
      if [ ${buildStatus} -eq 100 ]; then
        echo "`date +"%c"`: Server ${serverName} for ${ACCT} build complete!"
        if [ "${DC}" == "VA1" ]; then
          ID="2357"
        elif [ "${DC}" == "GB3" ]; then
          ID="2059"
        elif [ "${DC}" == "IL1" ]; then
          ID="2479"
        elif [ "${DC}" == "UC1" ]; then
          ID="2244"
        elif [ "${DC}" == "SG1" ]; then
          ID="696"
	fi
        managedJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"0d847eb5-0de6-48be-a5e2-ea5544af9768.TaskServer\",\"Value\":\"${serverName}\"},{\"Name\":\"c9b69147-9eae-4def-b1c3-17f296df52dc.TaskServer\",\"Value\":\"${serverName}\"},{\"Name\":\"dfda558b-fb54-4335-a6f3-b74c4f6a5f8e.TaskServer\",\"Value\":\"${serverName}\"}]}"
        managed=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${managedJSON}"`
        managedReqID=`echo ${managed} | jq -r .RequestID`
        if [ ${managedReqID} -ne 0 ]; then
          echo "`date +"%c"`: Make Managed Blueprint started for ${serverName}. You will get an update every minute. Be patient, this could take up to an hour"

          # Don't move to make managed until server build is completed
          managedStatus="0"
          timer="0"
          while [ ${managedStatus} -ne 100 ]; do
            sleep 60
            getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${managedReqID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            managedStatus=`echo ${getStatus} | jq -r .PercentComplete`
            currentStatus=`echo ${getStatus} | jq -r .CurrentStatus`
            if [ "${currentStatus}" == "Failed" ]; then
              echo "`date +"%c"`: Make Managed Blueprint for ${basicServer} has failed! Please submit a ticket to noc@ctl.io for them to resume the job before you move on!"
              exit 1
            fi
            if [ ${managedStatus} -eq 0 ]; then
	      getAuth;
              getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"RequestID\":\"${managedReqID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
              managedStatus=`echo ${getStatus} | jq -r .PercentComplete`
            fi
            echo "`date +"%c"`: Server ${serverName} for ${ACCT} make managed blueprint is ${managedStatus}% complete..."
            timer=$(( timer + 1 ))
            if [ ${timer} -eq 20 ]; then
              break
            fi
          done

          # Wait for the server status to be active before moving on. This is so that make mananged can finish on the backend.
          serverStatus="UnderConstruction"
          until [ ${serverStatus} == "Active" ]; do
            echo "`date +"%c"`: Server ${serverName} still under construction, checking again in 2 minutes.."
            sleep 120
	    getAuth;
            check=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${serverName}\"}"`
            serverStatus=`echo ${check} | jq -r '.Server | .Status'`
          done

          echo "`date +"%c"`: Server ${serverName} is complete and ready for use."

          # Update SlimDB
          sudo -u siterun ./addToSlimDB.sh ${SITE_ID} ${serverName} ${ENV} ${ipAddress}

          return 0
        else
          echo "`date +"%c"`: Make Managed Blueprint for ${serverName} failed to run. Go figure out why!"
        fi
      else
        echo "`date +"%c"`: Build never finished for ${serverName}.. Go figure out why!"
        return 1
      fi
    else
      echo "`date +"%c"`: Build fileserver failed to run on ${ACCT}. Go figure out why. Bailing..."
      exit 1
    fi
  fi
}

function updateJSONfs {
  server_found=`jq '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${1}'")' ./${SITE_ID}.json`
  if [ -z "${server_found}" ]; then
    total=`jq '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | length' ./${SITE_ID}.json | wc -l`
    if [ -z "${total}" ]; then
      total="0"
    fi
    newJSON=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers['${total}']) |= { "Name" : "'${1}'","Type" : "Fileserver" }' ./${SITE_ID}.json`
    rm -rf ./${SITE_ID}.json
    echo ${newJSON} > ./${SITE_ID}.json
    updateOrchestrate;
  fi
}

# Main
getAuth;
found=$(getFileServers);
if [ ${found} -ne  0 ]; then
  echo "`date +"%c"`: All required ${ENV} FileServers for ${ACCT} are built. Moving on..."
else
  createFileServer;
  if [ "${?}" == "0" ]; then
    echo "`date +"%c"`: ${SITE_ID}.json updated with new server"
  fi
fi
