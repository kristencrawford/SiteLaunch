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
  echo "`date +"%c"`: The ${ENV} Alias is missing from ${SITE_ID}.json. IIS build cannot be completed without this information. Please ensure create subaccount finished successfully and updated the site's json."
  exit 1
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

#Orchestrate.io Information
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

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

function getIISServers {
  # Check iis server total before creating any servers
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - WEB") | .UUID' | sed "s/\"//g"`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq '.Servers | length'`
  echo ${existingServers}
}

function createIISServer {
  # Create build is server json
  getGroups=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}"`
  groupID=`echo ${getGroups} | jq '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - WEB") | .UUID' | sed "s/\"//g"`
  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  networkID=`echo ${getNetworks} | jq -r '.[] | select(.name=="'${SITE_ID}' - '${ENV}' - Web") | .id'`
  if [[ ${groupID} != "" && ${networkID} != "" ]]; then
    iisJSON="{\"name\":\"iis${1}\",\"description\":\"iis server\",\"groupId\":\"${groupID}\",\"sourceServerId\":\"VA1TCCCWABTMP02\",\"isManagedOS\":false,\"primaryDns\":\"172.17.1.26\",\"networkId\":\"${networkID}\",\"cpu\":1,\"memoryGB\":2,\"type\":\"standard\",\"storageType\":\"standard\",\"Packages\":[{\"packageID\":\"20160303-1e49-486b-932c-f3b3f35c8d14\"}]}"
    # Build IIS Server
    build=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "${iisJSON}"`
    requestID=`echo ${build} | jq -r '.links[] | select(.rel=="status") | .id' 2> /dev/null | awk -F- '{print $2}'`
    if [ "${requestID}" != "" ]; then
      echo ${requestID}
    else
      echo "0"
    fi
  fi
}

function makeManagedIIS {
  # Re-login just in case
  getAuth;
  if [ "${DC}" == "VA1" ]; then
    ID="1461"
  elif [ "${DC}" == "GB3" ]; then
    ID="262"
  elif [ "${DC}" == "IL1" ]; then
    ID="1643"
  elif [ "${DC}" == "UC1" ]; then
    ID="1443"
  elif [ "${DC}" == "SG1" ]; then
    SG1="678"
  fi
  managedJSON="{\"ID\":\"${ID}\",\"LocationAlias\":\"${DC}\",\"Parameters\":[{\"Name\":\"e5c0f87c-1abf-4485-9aa8-22fcc032f833.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"d6187c28-7061-4971-8c6e-41ded506dbee.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"a8d2c77d-b27b-42db-8808-e22777371de9.TaskServer\",\"Value\":\"${1}\"},{\"Name\":\"e416d357-3c31-4d83-b79c-08ca27b74c85.TaskServer\",\"Value\":\"${1}\"}]}"
  managed=`curl -s "https://${ENDPOINT}/REST/Blueprint/DeployBlueprint/JSON" -XPOST -H "Content-type: application/json" -b "acctCookies.txt" -d "${managedJSON}"`
  echo "${managed}" >> managed
  managedReqID=`echo ${managed} | jq -r .RequestID`
  echo ${managedReqID}
}

function updateJSONIIS {
  server_found=`jq '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${1}'")' ./${SITE_ID}.json`
  if [ -z "${server_found}" ]; then
    total=`jq '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | length' ./${SITE_ID}.json | wc -l`
    if [ -z "${total}" ]; then
      total="0"
    fi
    newJSON=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers['${total}']) |= { "Name" : "'${1}'","Type" : "IIS","Middleware" : "_NewServer_" }' ./${SITE_ID}.json`
    rm -rf ./${SITE_ID}.json
    echo ${newJSON} > ./${SITE_ID}.json
    echo "`date +"%c"`: ${SITE_ID}.json updated with new server"
    updateOrchestrate;
  fi
}

# Main
getAuth;
found=$(getIISServers);
echo "${found}"
if [ ${found} -eq 0 ]; then
  if [ "${REF_ARCH}" == "Basic" ]; then
    basicRequestID=$(createIISServer 1);
    if [ ${basicRequestID} -ne 0 ]; then
      echo "`date +"%c"`: Build IIS server on ${ACCT} has been queued. You will get an update every minute."

      # Don't move to make managed until server build is completed
      basicBuildPercent="0"
      timer="0"
      while [ ${basicBuildPercent} -ne 100 ]; do
        sleep 60
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicRequestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        basicBuildPercent=`echo ${getStatus} | jq -r .PercentComplete`
        if [ ${basicBuildPercent} -eq 0 ]; then
          getAuth;
          getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicRequestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          basicBuildPercent=`echo ${getStatus} | jq -r .PercentComplete`
        fi
        basicServer=`echo ${getStatus} | jq -r .Servers | grep IIS1 | sed "s/\"//g" | sed "s/\ //g"`
        echo "`date +"%c"`: Server ${basicServer} for ${ACCT} build is ${basicBuildPercent}% complete..."
        timer=$(( timer + 1 ))
        if [ ${timer} == 20 ]; then
          break
        fi
      done

      # Ensure Server is ready for make managed and get IP for later push to slimdb
      ipAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${basicServer}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
      while [ "${ipAddress}" == "" ]; do
        sleep 5
        ipAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${basicServer}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
      done

      if [ ${basicBuildPercent} -eq 100 ]; then
        basicManagedID=$(makeManagedIIS ${basicServer});
        if [ ${basicManagedID} -ne 0 ]; then
          echo "`date +"%c"`: Make Managed Blueprint started for ${basicServer}. You will get an update every minute. Be patient, this could take up to an hour"

          # Don't move to make managed until server build is completed
          managedStatus="0"
          timer="0"
          while [ ${managedStatus} -ne 100 ]; do
            sleep 60
            getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicManagedID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            managedStatus=`echo ${getStatus} | jq -r .PercentComplete`
            currentStatus=`echo ${getStatus} | jq -r .CurrentStatus`
            if [ "${currentStatus}" == "Failed" ]; then
              echo "`date +"%c"`: Make Managed Blueprint for ${basicServer} has failed! Please submit a ticket to noc@ctl.io for them to resume the job before you move on!"
              exit 1
            fi
            if [ ${managedStatus} -eq 0 ]; then
              getAuth;
              getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicManagedID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
              managedStatus=`echo ${getStatus} | jq -r .PercentComplete`
            fi
            echo "`date +"%c"`: Server ${basicServer} for ${ACCT} make managed blueprint is ${managedStatus}% complete..."
            timer=$(( timer + 1 ))
            if [ ${timer} -eq 20 ]; then
              break
            fi
          done

          # Update JSON
          updateJSONIIS ${basicServer};

          # Wait for the server status to be active before moving on. this is so that make mananged can finish on the backend.  Even though the bp reports done, it is not :(
          serverStatus="UnderConstruction"
          until [ ${serverStatus} == "Active" ]; do
            echo "`date +"%c"`: Server ${basicServer} still under construction, checking again in 2 minutes.."
            sleep 120
            getAuth;
            check=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${basicServer}\"}"`
            serverStatus=`echo ${check} | jq -r '.Server | .Status'`
          done

          echo "`date +"%c"`: Server ${basicServer} is complete and ready for use."

          # Update SlimDB
          sudo -u siterun ./addToSlimDB.sh ${SITE_ID} ${basicServer} ${ENV} ${ipAddress}

        else
          echo "`date +"%c"`: Make Managed Blueprint for ${basicServer} failed to run. Go figure out why!"
        fi
      else
        echo "`date +"%c"`: Build IIS server failed to finish.. Go figure out why! Bailing..."
        exit
      fi
    else
      echo "`date +"%c"`: Build iis server failed to run.. Either the blueprint failed to finish or the network or group have not been created!! Bailing..."
      exit 1
    fi

  elif [ "${REF_ARCH}" == "Standard" ]; then
    standardReqID1=$(createIISServer 1);
    standardReqID2=$(createIISServer 2);
    echo "${standardReqID1} ${standardReqID2}"
    if [[ ${standardReqID1} -gt 0 && ${standardReqID2} -gt 0 ]]; then
      echo "`date +"%c"`: Build iis standard servers on ${ACCT} have been queued. You will get an update every minute."

      # Don't move to make managed until server build is completed
      buildPercent1="0"
      buildPercent2="0"
      timer="0"
      while [ ${buildPercent1} -lt 100 ]; do
        while [ ${buildPercent2} -lt 100 ]; do
          sleep 60
          getBuildStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardReqID1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          buildPercent1=`echo ${getBuildStatus1} | jq -r .PercentComplete`
          getBuildStatus2=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardReqID2}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          buildPercent2=`echo ${getBuildStatus2} | jq -r .PercentComplete`
          if [[ ${buildPercent1} -eq 0 || ${buildPercent2} -eq 0 ]]; then
            getAuth;
            getBuildStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardReqID1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            buildPercent1=`echo ${getBuildStatus1} | jq -r .PercentComplete`
            getBuildStatus2=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardReqID2}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            buildPercent2=`echo ${getBuildStatus2} | jq -r .PercentComplete`
          fi
          standardServer1=`echo ${getBuildStatus1} | jq -r .Servers | grep IIS1 | sed "s/\"//g" | sed "s/\ //g"`
          standardServer2=`echo ${getBuildStatus2} | jq -r .Servers | grep IIS2 | sed "s/\"//g" | sed "s/\ //g"`
          echo "`date +"%c"`: Server ${standardServer1} for ${ACCT} build is ${buildPercent1}% complete..."
          echo "`date +"%c"`: Server ${standardServer2} for ${ACCT} build is ${buildPercent2}% complete..."
          timer=$(( timer + 1 ))
          if [ ${timer} == 20 ]; then
            break
          fi
        done

        # Ensure Server is ready for make managed and get IP for later push to slimdb
        ipAddress1=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${standardServer1}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
        while [ "${ipAddress1}" == "" ]; do
          sleep 5
          ipAddress1=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${standardServer1}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
        done

        # Ensure Server is ready for make managed and get IP for later push to slimdb
        ipAddress2=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${standardServer2}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
        while [ "${ipAddress2}" == "" ]; do
          sleep 5
          ipAddress2=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${standardServer2}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
        done

        if [ ${buildPercent1} -ne 100 ]; then
          sleep 60
          #If we made it here it is possible that the first server built is still not done.. so need to keep checking
          getBuildStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardReqID1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          buildPercent1=`echo ${getBuildStatus1} | jq -r .PercentComplete`
          if [ ${buildPercent1} -eq 0 ]; then
            getAccountAuth=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${ACCT_V1AUTH}"`
            getBuildStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardReqID1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            buildPercent1=`echo ${getBuildStatus1} | jq -r .PercentComplete`
          fi
          standardServer1=`echo ${getBuildStatus1} | jq -r .Servers | grep IIS1 | sed "s/\"//g" | sed "s/\ //g" | sed "s/\,//g"`
          echo "`date +"%c"`: Server ${standardServer1} for ${ACCT} build is ${buildPercent1}% complete..."
          timer1=$(( timer1 + 1 ))
          if [ ${timer1} -eq 10 ]; then
              break
          fi
        fi
      done

      # Once server builds are 100% completed, run make managed and move on
      if [[ ${buildPercent1} -eq 100 && ${buildPercent2} -eq 100 ]]; then
        standardManaged1=$(makeManagedIIS ${standardServer1});
        standardManaged2=$(makeManagedIIS ${standardServer2});
        if [[ ${standardManaged1} -gt 0 && ${standardManaged2} -gt 0 ]]; then
          echo "`date +"%c"`: Make Managed Blueprint started for ${standardServer1} and ${standardServer2}. You will get an update every minute. Be patient, this could take up to an hour"
          # Don't move to make managed until server build is completed
          managedPercent1="0"
          managedPercent2="0"
          timer="0"
          while [ ${managedPercent1} -lt 100 ]; do
            while [ ${managedPercent2} -lt 100 ]; do
              sleep 60
              getStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardManaged1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
              managedPercent1=`echo ${getStatus1} | jq -r .PercentComplete`
              currentStatus1=`echo ${getStatus1} | jq -r .CurrentStatus`
              getStatus2=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardManaged2}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
              managedPercent2=`echo ${getStatus2} | jq -r .PercentComplete`
              currentStatus2=`echo ${getStatus2} | jq -r .CurrentStatus`
              if [ "${currentStatus1}" == "Failed" ]; then
                echo "`date +"%c"`: Make Managed Blueprint for ${standardServer1} has failed! Please submit a ticket to noc@ctl.io for them to resume the job before you move on!"
                exit 1
              fi
              if [ "${currentStatus2}" == "Failed" ]; then
                echo "`date +"%c"`: Make Managed Blueprint for ${standardServer2} has failed! Please submit a ticket to noc@ctl.io for them to resume the job before you move on!"
                exit 1
              fi
              if [[ ${managedPercent1} -eq 0 || ${managedPercent2} -eq 0 ]]; then
                getAuth;
                getStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardManaged1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
                managedPercent1=`echo ${getStatus1} | jq -r .PercentComplete`
                getStatus2=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardManaged2}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
                managedPercent2=`echo ${getStatus2} | jq -r .PercentComplete`
              fi
              echo "`date +"%c"`: Server ${standardServer1} for ${ACCT} make managed blueprint is ${managedPercent1}% complete..."
              echo "`date +"%c"`: Server ${standardServer2} for ${ACCT} make managed blueprint is ${managedPercent2}% complete..."
              timer=$(( timer + 1 ))
              if [ ${timer} -eq 20 ]; then
                break
              fi
            done
            if [ ${managedPercent1} -ne 100 ]; then
              sleep 60
              #If we made it here it is possible that the first server built is still not done.. so need to keep checking
              getStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardManaged1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
              managedPercent1=`echo ${getStatus1} | jq -r .PercentComplete`
              if [ ${managedPercent1} -eq 0 ]; then
                getAuth;
                getStatus1=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${standardManaged1}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
                managedPercent1=`echo ${getStatus1} | jq -r .PercentComplete`
              fi
              echo "`date +"%c"`: Server ${standardServer1} for ${ACCT} make managed blueprint is ${managedPercent1}% complete..."
              timer1=$(( timer1 + 1 ))
              if [ ${timer1} -eq 10 ]; then
                break
              fi
            fi
          done

          # Update JSON
          updateJSONIIS ${standardServer1};
          updateJSONIIS ${standardServer2};

          # Wait for the server status to be active before moving on. this is so that make mananged can finish on the backend.  Even though the bp reports done, it is not :(
          serverStatus1="UnderConstruction"
          serverStatus2="UnderConstruction"
          until [[ ${serverStatus1} == "Active" && ${serverStatus2} == "Active" ]]; do
            echo "`date +"%c"`: Servers ${standardServer1} and ${standardServer2} are still under construction, checking again in 2 minutes.."
            sleep 120
            getAuth;
            check1=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${standardServer1}\"}"`
            serverStatus1=`echo ${check1} | jq -r '.Server | .Status'`
            check2=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${standardServer2}\"}"`
            serverStatus2=`echo ${check2} | jq -r '.Server | .Status'`
          done

          echo "`date +"%c"`: Servers ${standardServer1} and ${standardServer2} are completed and ready for use."

          # Update SlimDB
          sudo -u siterun ./addToSlimDB.sh ${SITE_ID} ${standardServer1} ${ENV} ${ipAddress1}
          sudo -u siterun ./addToSlimDB.sh ${SITE_ID} ${standardServer2} ${ENV} ${ipAddress2}

        else
          echo "`date +"%c"`: Make Managed Blueprint for ${standardServer1} or ${standardServer2} failed to run. Go figure out why!"
        fi
      else
        echo "`date +"%c"`: Build standard iis servers for ${ACCT} failed to finish. Go figure out why! Bailing..."
        exit 1
      fi
    else
      echo "`date +"%c"`: Build standard iis for ${ACCT} failed to run.. Either the blueprint failed to finish or the network or group have not been created!! Bailing..."
      exit 1
    fi
  else
    echo "`date +"%c"`: No Reference Architecture was found! This should not have happened..."
  fi
elif [ ${found} -eq 1 ]; then
  if [ ${REF_ARCH} == "Basic" ]; then
    echo "`date +"%c"`: The required Basic ${ENV} IIS Server for ${ACCT} is built. Moving on..."
  elif [ ${REF_ARCH} == "Standard" ]; then
    basicRequestID=$(createIISServer 2);
    if [ ${basicRequestID} -ne 0 ]; then
      echo "`date +"%c"`: Build iis server on ${ACCT} has been queued. You will get an update every minute."

      # Don't move to make managed until server build is completed
      basicBuildPercent="0"
      timer="0"
      while [ ${basicBuildPercent} -ne 100 ]; do
        sleep 60
        getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicRequestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
        basicBuildPercent=`echo ${getStatus} | jq -r .PercentComplete`
        if [ ${basicBuildPercent} -eq 0 ]; then
          getAuth;
          getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicRequestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
          basicBuildPercent=`echo ${getStatus} | jq -r .PercentComplete`
        fi
        basicServer=`echo ${getStatus} | jq -r .Servers | grep IIS2 | sed "s/\"//g" | sed "s/\ //g"`
        echo "`date +"%c"`: Server ${basicServer} for ${ACCT} build is ${basicBuildPercent}% complete..."
        timer=$(( timer + 1 ))
        if [ ${timer} == 20 ]; then
          break
        fi
      done

      # Ensure Server is ready for make managed and get IP for later push to slimdb
      ipAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${basicServer}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
      while [ "${ipAddress}" == "" ]; do
        sleep 5
        ipAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${basicServer}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.details | .ipAddresses[] | .internal' 2> /dev/null`
      done

      # Once server build is at 100% completed, run make managed and move on
      if [ ${basicBuildPercent} -eq 100 ]; then
        basicManagedID=$(makeManagedIIS ${basicServer});
        if [ ${basicManagedID} -ne 0 ]; then
          echo "`date +"%c"`: Make Managed Blueprint started for ${basicServer}. You will get an update every minute. Be patient, this could take up to an hour"

          # Don't move to make managed until server build is completed
          managedStatus="0"
          timer="0"
          while [ ${managedStatus} -ne 100 ]; do
            sleep 60
            getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicManagedID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
            managedStatus=`echo ${getStatus} | jq -r .PercentComplete`
            currentStatus=`echo ${getStatus} | jq -r .CurrentStatus`
            if [ "${currentStatus}" == "Failed" ]; then
              echo "`date +"%c"`: Make Managed Blueprint for ${basicServer} has failed! Please submit a ticket to noc@ctl.io for them to resume the job before you move on!"
              exit 1
            fi
            if [ ${managedStatus} -eq 0 ]; then
              getAuth;
              getStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${basicManagedID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}"`
              managedStatus=`echo ${getStatus} | jq -r .PercentComplete`
            fi
            echo "`date +"%c"`: Server ${basicServer} for ${ACCT} make managed blueprint is ${managedStatus}% complete..."
            timer=$(( timer + 1 ))
            if [ ${timer} -eq 20 ]; then
              break
            fi
          done

          # Update JSON
          updateJSONIIS ${basicServer};

          # Wait for the server status to be active before moving on. this is so that make mananged can finish on the backend.  Even though the bp reports done, it is not :(
          serverStatus="UnderConstruction"
          until [ ${serverStatus} == "Active" ]; do
            echo "`date +"%c"`: Server ${basicServer} still under construction, checking again in 2 minutes.."
            sleep 120
            getAuth;
            check=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${basicServer}\"}"`
            serverStatus=`echo ${check} | jq -r '.Server | .Status'`
          done

          echo "`date +"%c"`: Server ${basicServer} is complete and ready for use."

          # Update SlimDB
          sudo -u siterun ./addToSlimDB.sh ${SITE_ID} ${basicServer} ${ENV} ${ipAddress}

        else
          echo "`date +"%c"`: Make Managed Blueprint for ${basicServer} failed to run. Go figure out why!"
        fi
      else
        echo "`date +"%c"`: Build IIS server failed to finish.. Go figure out why! Bailing..."
        exit
      fi
    else
      echo "`date +"%c"`: Build iis server failed to run.. Either the blueprint failed to finish or the network or group have not been created!! Bailing..."
      exit 1
    fi
  else
    echo "`date +"%c"`: No Reference Architecture was found for ${ACCT}! This should not have happened..."
  fi
else
  echo "`date +"%c"`: The required ${ENV} IIS Servers for ${ACCT} are built. Moving on..."
fi

