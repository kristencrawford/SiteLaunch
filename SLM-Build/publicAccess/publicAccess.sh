#!/bin/bash

#
#     _____            _                    _     _       _      _____ _                 _
#     /  __ \          | |                  | |   (_)     | |    /  __ \ |               | |
#     | /  \/ ___ _ __ | |_ _   _ _ __ _   _| |    _ _ __ | | __ | /  \/ | ___  _   _  __| |
#     | |    / _ \ '_ \| __| | | | '__| | | | |   | | '_ \| |/ / | |   | |/ _ \| | | |/ _` |
#     | \__/\  __/ | | | |_| |_| | |  | |_| | |___| | | | |   <  | \__/\ | (_) | |_| | (_| |
#      \____/\___|_| |_|\__|\__,_|_|   \__, \_____/_|_| |_|_|\_\  \____/_|\___/ \__,_|\__,_|
#                                        __/ |
#                                       |___/
#
#    publicAccess.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Add VIP to  Alert logic sites
#    Add Load balancer for standard sites
#
#### Changelog
#
##   2016.02.24 <kristen.crawford@centurylink.com>
## - Initial release
#
## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
ADD_DC="${3}"

# Verify who is running the script so you know which db to use.  Root writes to Test and udeploy writes to Prod (through udeploy)
user=`whoami`
if [ "${user}" == "root" ]; then
  db="Test"
elif [ "${user}" == "udeploy" ]; then
  db="Prod"
else
  echo "`date +"%c"`: ${user} is not authorized to update slimdb! Please use udeploy user (via udeploy)"
fi

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"

#Orchestrate.io Information
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
    NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    SERVICE_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
    SEC_TIER=`jq -r .SecurityTier ./${SITE_ID}.json`
    URL=`jq -r .URL ./${SITE_ID}.json`
    INC=`jq -r '.Environments[] | select(.Name=="Production") | .RemedyRequest' ./${SITE_ID}.json`
    FNAME=`jq -r '.Requestors[0] | .FirstName' ./${SITE_ID}.json`
    LNAME=`jq -r '.Requestors[0] | .LastName' ./${SITE_ID}.json`
    EMAIL=`jq -r '.Requestors[0] | .Email' ./${SITE_ID}.json`
    ALOGIC=`jq -r .Alertlogic ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi

  if [ "${ALOGIC}" == "Completed" ]; then
    echo "`date +"%c"`: The Alertlogic configure email request has already been sent to the Alogic Support.  Moving on..."
    rm ./${SITE_ID}.json
    exit
  fi
}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

function createPublicVIP {
  getAuth;
  # Create Public VIP on the web server
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - WEB") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServer=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  if [ `echo ${existingServer} | wc -w` == 1 ]; then
    serverRIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${existingServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
    # Check to see if the Public VIP is already created
    serverMIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${existingServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
    if [ -z ${serverMIP} ]; then
      addPublicAddress=`curl -s "https://${ENDPOINT}/REST/Network/AddPublicIPAddress/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"ServerName\":\"${existingServer}\",\"IPaddress\":\"${serverRIP}\",\"AllowHTTP\":true,\"AllowHTTPS\":true}"`
      requestID=`echo ${addPublicAddress} | jq .RequestID`
      mipStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}" | jq -r .CurrentStatus`
      while [[ "${mipStatus}" == "Executing" || "${mipStatus}" == "NotStarted" || "${mipStatus}" == "Resumed" ]]; do
        echo "`date +"%c"`: Public VIP on ${existingServer} for ${ACCT} creation in progress..."
        sleep 30
        mipStatus=`curl -s "https://${ENDPOINT}/REST/Blueprint/GetDeploymentStatus/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"RequestID\":\"${requestID}\",\"LocationAlias\":\"${DC}\",\"AccountAlias\":\"${ACCT}\"}" | jq -r .CurrentStatus`
      done
      if [ "${mipStatus}" == "Succeeded" ]; then
        serverMIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${existingServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
        echo "`date +"%c"`: Public VIP ${serverMIP} has been added to ${existingServer} on Account Alias ${ACCT} successfully"
      else
        echo "`date +"%c"`: Adding Public VIP to ${existingServer} failed on Account Alias ${ACCT}! Go see why.. "
      fi
    else
      echo "`date +"%c"`: ${existingServer} on Account Alias ${ACCT} already has a Public VIP assigned -> ${serverMIP}, moving on..."
    fi
  addMipToDBs ${serverMIP};
  fi
}

function createAlPublicVIP {
  getAuth;
  # Create Public VIP on the alogic
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - DMZ") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServer=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  if [ `echo ${existingServer} | wc -w` -eq 1 ]; then
    existingMIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${existingServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
    alogicRIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${existingServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
    if [ `echo ${existingMIP} | wc -w` -eq 1 ]; then
      addPublicAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${existingServer}/publicIPAddresses" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "{\"ports\":[{\"protocol\":\"TCP\",\"port\":80},{\"protocol\":\"TCP\",\"port\":443}]}"`
      request=`echo ${addPublicAddress} | jq -r .href`
      mipStatus="notStarted"
      while [[ "${mipStatus}" != "succeeded" ]]; do
        echo "`date +"%c"`: Public VIP on ${existingServer} for ${ACCT} creation in progress..."
        sleep 30
        mipStatus=`curl -s "https://${ENDPOINT}/${request}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
      done
      # Sleep for 30 seconds just to make sure the server is updated for the next get server check
      sleep 30
      if [ "${mipStatus}" == "succeeded" ]; then
        newMIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${existingServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="MIP") | .Address' | grep -v ${existingMIP}`
        echo "`date +"%c"`: Public VIP ${newMIP} has been added to ${existingServer} on Account Alias ${ACCT} successfully"
        webGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - '${ENV}' - WEB") | .UUID'`
        getWebGroup=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${webGroupID}\",\"Location\":\"${DC}\"}"`
       	webServer=`echo ${getWebGroup} | jq -r '.Servers[] | .Name'`
	if [ `echo ${webServer} | wc -w` -eq 1 ]; then
	  webRIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${webServer}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
        fi
        # Email Alogic with necessary info to configure
        emailAlogic ${existingMIP} ${alogicRIP} ${webRIP} ${newMIP}
	# Add new public vip to slimdb
	addMipToDBs ${newMIP};
      else
        echo "`date +"%c"`: Adding Alogic Public VIP to ${existingServer} failed on Account Alias ${ACCT}! Go see why.. "
      fi
    elif [ `echo ${existingMIP} | wc -w` -eq 0 ]; then
      echo "`date +"%c"`: The AlertLogic VIP has not been created yet, so the Alogic public VIP cannot be created either.  Re-run this process"
      exit 1
    else
      echo "`date +"%c"`: ${existingServer} on Account Alias ${ACCT} already has all the necessary public VIP's, moving on..."
    fi
  else
    echo "`date +"%c"`: There are more alert logic servers than there should be for a basic site!  Go figure out whats up..."
    exit 1
  fi
}

function createAlogicVIP {
  getAuth;
  # Create Public VIP on the logic
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - Production - DMZ") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServer=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  if [ `echo ${existingServer} | wc -w` -eq 0 ]; then
    echo "`date +"%c"`: The alertlogic servers have not been created yet. Skipping public access till alertlogic servers are completed. Moving on..."
    exit 0
  else
    declare -a "alogicsServers=($existingServer)"  
    for c in "${alogicsServers[@]}"; do
      serverRIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${c}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
      # Check to see if the Public VIP is already created
      serverMIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${c}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
      if [ -z ${serverMIP} ]; then
        addPublicAddress=`curl -s "https://${ENDPOINT}/v2/servers/${ACCT}/${c}/publicIPAddresses" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "{\"ports\":[{\"protocol\":\"TCP\",\"port\":80},{\"protocol\":\"TCP\",\"port\":443},{\"protocol\":\"TCP\",\"port\":4849},{\"protocol\":\"TCP\",\"port\":22}],\"sourceRestrictions\":[{\"cidr\":\"204.110.219.96/27\"},{\"cidr\":\"204.110.218.96/27\"}],\"internalIPAddress\":\"${serverRIP}\"}"`
        request=`echo ${addPublicAddress} | jq -r .href`
        mipStatus="notStarted"
        while [[ "${mipStatus}" != "succeeded" ]]; do
          echo "`date +"%c"`: Alogic VIP on ${c} for ${ACCT} creation in progress..."
          sleep 30
	  mipStatus=`curl -s "https://${ENDPOINT}/${request}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        done
        # Sleep for 30 seconds just to make sure the server is updated for the next get server check
        sleep 30
        if [ "${mipStatus}" == "succeeded" ]; then
          serverMIP=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${c}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
          echo "`date +"%c"`: Alogic VIP ${serverMIP} has been added to ${c} on Account Alias ${ACCT} successfully"
        else
          echo "`date +"%c"`: Adding Alogic VIP to ${c} failed on Account Alias ${ACCT}! Go see why.. "
        fi
      else
        echo "`date +"%c"`: Account Alias ${ACCT} already has all the necessary alogic VIP's, moving on..."
      fi
    done
  fi
}


function createSharedLB {
  getAuth;
  existing=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '.[] | length' | wc -l`
  if [ ${existing} -eq 0 ]; then
    createLB=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "{\"name\":\"${SITE_ID} - ${ENV}\",\"description\":\"${SITE_ID} - ${ENV}\"}"`
    lbID=`echo ${createLB} | jq -r .id`
    if [ ! -z ${lbID} ]; then
      checkLB="0"
      while [ ${checkLB} -eq 0 ]; do
        sleep 10
        checkLB=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}" -XGET -H "Authorization: Bearer ${TOKEN}"  | jq '.[] | length' | wc -l`
      done
    fi
    echo "`date +"%c"`: Shared load balancer: ${SITE_ID} - ${ENV} has been created"
  else
    echo "`date +"%c"`: Shared load balancer: ${SITE_ID} - ${ENV} already exists. Moving on.."
    #Get and Set lbID since we may still need it
    lbID=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | .id'`
  fi
}

function createPools {
  getAuth;
  for p in 80 443; do
    poolID=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | select (.port=='${p}') | .id'`
    if [ "${poolID}" == "" ]; then
      createPool=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "{\"port\":${p}}"`
      poolID=`echo ${createPool} | jq -r .id`
      if [ "${poolID}" == "" ]; then
        checkPool="0"
        while [ ${checkPool} -eq 0 ]; do
          sleep 10
          checkPool=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools/${poolID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length' | wc -l`
        done
      fi
      echo "`date +"%c"`: Port ${p} Pool has been created on shared load balancer -> ${SITE_ID} - ${ENV}"
    else
      echo "`date +"%c"`: Port ${p} Pool already exists on the shared balancer -> ${SITE_ID} - ${ENV}"
    fi
  done
}

function updatePoolNodes {
  getAuth;
  getServers=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | .Name' ./${SITE_ID}.json`
  declare -a "pools=($getServers)"

  for t in 80 443; do
    nodeJSON="[]"
    for s in "${pools[@]}"; do
      if [[ "${s}" =~ "WEB" || "${s}" =~ "WA" || "${s}" =~ "IIS" ]]; then
        total=`echo ${nodeJSON} | jq '.[] | length' | wc -l`
        if [ -z "${total}" ]; then
          total="0"
        fi
        ipAddress=`/usr/bin/dig +short ${s}.${DC}.savvis.net`
        newJSON=`echo ${nodeJSON} | jq '.['${total}'] |= .+ {"ipAddress":"'${ipAddress}'","privatePort":'${t}'}'`
        nodeJSON="${newJSON}"
        getPoolID=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | select (.port=='${t}') | .id'`
        updateNode=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools/${getPoolID}/nodes" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPUT -H "Content-type: application/json" -d "${nodeJSON}"`

        if [ "${updateNode}" == "" ]; then
          echo "`date +"%c"`: Pool members ${s}:${t} have been added to the shared load balancer -> ${SITE_ID} - ${ENV}"
        else
          echo "`date +"%c"`: Pool members ${s}:${t} were NOT added to the shared load balancer -> ${SITE_ID} - ${ENV}.  The error given is: ${updateNode}"
        fi
      fi
    done
  done

}

function updateAlogicNodes {
  getAuth;
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - Production - DMZ") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  getServers=`echo ${getExisting} | jq -r '.Servers[] | .Name'`
  declare -a "alogicPools=($getServers)"

  for a in 80 443; do
    nodeJSON="[]"
    for b in "${alogicPools[@]}"; do  
      total=`echo ${nodeJSON} | jq '.[] | length' | wc -l`
      if [ -z "${total}" ]; then
        total="0"
      fi
      ipAddress=`curl -s "https://${ENDPOINT}/REST/Server/GetServer/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Name\":\"${b}\"}" | jq -r '.Server | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
      newJSON=`echo ${nodeJSON} | jq '.['${total}'] |= .+ {"ipAddress":"'${ipAddress}'","privatePort":'${a}'}'`
      nodeJSON="${newJSON}"
    done
    getPoolID=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | select (.port=='${a}') | .id'`
    updateNode=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}/${lbID}/pools/${getPoolID}/nodes" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPUT -H "Content-type: application/json" -d "${nodeJSON}"`
    if [ "${updateNode}" == "" ]; then
      echo "`date +"%c"`: Pool member ${alogicPools[0]}:${a} and ${alogicPools[1]}:${a} have been added to the shared load balancer -> ${SITE_ID} - ${ENV}"
    else
      echo "`date +"%c"`: Pool members ${alogicPools[0]}:${a} and ${alogicPools[1]}:${a} were NOT added to the shared load balancer -> ${SITE_ID} - ${ENV}.  The error given is: ${updateNode}"
      exit 1
    fi
  done
  
  emailAlogic;
}

function emailAlogic {
  getAuth;
  webGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - Production - WEB") | .UUID'`
  dmzGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - Production - DMZ") | .UUID'`
  getWeb=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${webGroupID}\",\"Location\":\"${DC}\"}"`
  getDMZ=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${dmzGroupID}\",\"Location\":\"${DC}\"}"`

  if [ "${REF_ARCH}" == "Basic" ]; then
    if [ $# -ne 4 ]; then
      echo "Received: $@"
      echo "`date +"%c"`: All required information needed to send the setup email to Alertlogic was not given. Please send it manually."
      exit 1
    fi

    ALNAME=`echo ${getDMZ} | jq -r '.Servers[0] | .Name'`

    cp ./alogicBasicTemplate.txt ${SITE_ID}.txt
    sed -i -e "s/__MIP__/${1}/g" ./${SITE_ID}.txt
    sed -i -e "s/__RIP__/${2}/g" ./${SITE_ID}.txt
    sed -i -e "s/__WIP__/${3}/g" ./${SITE_ID}.txt
    sed -i -e "s/__VIP__/${4}/g" ./${SITE_ID}.txt
    sed -i -e "s/__ALName__/${ALNAME}/g" ./${SITE_ID}.txt
    if [ "${URL}" != "null" ]; then
      sed -i -e "s/__URL__/${URL}/g" ./${SITE_ID}.txt
    else
      sed -i -e "s/__URL__/${4}/g" ./${SITE_ID}.txt
    fi

  elif [ "${REF_ARCH}" == "Standard" ]; then
    # For Basic all the info is passed, for standard there is no way to pass it, so it has to be gathered
    WIP1=`echo ${getWeb} | jq -r '.Servers[0] | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
    WIP2=`echo ${getWeb} | jq -r '.Servers[1] | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
    MIP1=`echo ${getDMZ} | jq -r '.Servers[0] | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
    RIP1=`echo ${getDMZ} | jq -r '.Servers[0] | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
    MIP2=`echo ${getDMZ} | jq -r '.Servers[1] | .IPAddresses[] | select (.AddressType=="MIP") | .Address'`
    RIP2=`echo ${getDMZ} | jq -r '.Servers[1] | .IPAddresses[] | select (.AddressType=="RIP") | .Address'`
    VIP=`curl -s "https://${ENDPOINT}/v2/sharedLoadBalancers/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | .ipAddress'`
    ALNAME1=`echo ${getDMZ} | jq -r '.Servers[0] | .Name'`
    ALNAME2=`echo ${getDMZ} | jq -r '.Servers[1] | .Name'`
 
    cp ./alogicStandardTemplate.txt ${SITE_ID}.txt
    sed -i -e "s/__MIP1__/${MIP1}/g" ./${SITE_ID}.txt
    sed -i -e "s/__RIP1__/${RIP1}/g" ./${SITE_ID}.txt
    sed -i -e "s/__MIP2__/${MIP2}/g" ./${SITE_ID}.txt
    sed -i -e "s/__RIP2__/${RIP2}/g" ./${SITE_ID}.txt
    sed -i -e "s/__WIP1__/${WIP1}/g" ./${SITE_ID}.txt
    sed -i -e "s/__WIP2__/${WIP2}/g" ./${SITE_ID}.txt
    sed -i -e "s/__VIP__/${VIP}/g" ./${SITE_ID}.txt
    sed -i -e "s/__ALName1__/${ALNAME1}/g" ./${SITE_ID}.txt
    sed -i -e "s/__ALName2__/${ALNAME2}/g" ./${SITE_ID}.txt
    if [ "${URL}" != "" ]; then
      sed -i -e "s/__URL__/${URL}/g" ./${SITE_ID}.txt
    else
      sed -i -e "s/__URL__/${VIP}/g" ./${SITE_ID}.txt
    fi
  else
    echo "No Reference Architecture Found! Bailing..."
    exit 1
  fi

  #All items below will exist in both templates so they can be done outside of the if statement
  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  networkID=`echo ${getNetworks} | jq -r '.[] | select(.name=="'${SITE_ID}' - '${ENV}' - DMZ") | .id'`
  GATEWAY=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}/${networkID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .gateway`

  sed -i -e "s/__AppID__/${SITE_ID}/g" ./${SITE_ID}.txt
  sed -i -e "s/__AppName__/${NAME}/g" ./${SITE_ID}.txt
  sed -i -e "s/__First__/${FNAME}/g" ./${SITE_ID}.txt
  sed -i -e "s/__Last__/${LNAME}/g" ./${SITE_ID}.txt
  sed -i -e "s/__Email__/${EMAIL}/g" ./${SITE_ID}.txt
  sed -i -e "s/__Gateway__/${GATEWAY}/g" ./${SITE_ID}.txt

  mutt -e "my_hdr From:adaptivesupport@centurylink.com" -s "WSM site addition for Coca-Cola ( ${ACCT} / ${SITE_ID} / Build / ${INC} )" tcccorders@alertlogic.com TCCCAlertLogic@2ndwatch.com -c kristen.crawford@centurylink.com tony.martin@centurylink.com <  ${SITE_ID}.txt
  if [ $? -eq 0 ]; then
    echo "`date +"%c"`: Email requesting Alogic to configure the  appliances has been sent."
    # Mark email sent
    updateAlogic=`jq '. |= .+ {"Alertlogic": "Completed"}' ./${SITE_ID}.json`
    rm -rf ./${SITE_ID}.json
    echo ${updateAlogic} > ./${SITE_ID}.json
    updateOrchestrate;
  else
    echo "`date +"%c"`: Email requesting Alogic to configure the appliances has not been sent! Please send it manually"
  fi
  
  #cleanup
  rm ./${SITE_ID}.txt
}

function addMipToDBs {
  # Update Orchestrate
  newJSON=`jq '(.Environments[] | select(.Name=="'${ENV}'")) |= .+ {"VIP": "'${1}'"}' ./${SITE_ID}.json`
  rm -rf ./${SITE_ID}.json
  echo ${newJSON} > ./${SITE_ID}.json
  echo "`date +"%c"`: ${SITE_ID}.json updated with ${ENV} VIP"
  updateOrchestrate;

  # Update Slimdb
  if [ "${ENV}" == "Production" ]; then
    ENV_ID="${SITE_ID}-00"
  elif [ "${ENV}" == "Test" ]; then
    ENV_ID="${SITE_ID}-01"
  elif [ "${ENV}" == "Dev" ]; then
    ENV_ID="${SITE_ID}-02"
  fi

  insertVIP=`mysql -e "UPDATE SLIMDB_${db}.sites SET appVip='${1}' where siteId='${ENV_ID}';" 2>&1`
  if [ "${insertVIP}" == "" ]; then
    echo "`date +"%c"`: ${ENV} VIP ${1} has been added to the SLIM Database for ${SITE_ID}"
  else
    echo "`date +"%c"`: ${ENV} VIP ${1} was not added to the slim db. Error: ${insertServer}"
  fi
}

## Main
getAuth;
getSiteInfo;
#updateOrchestrate;
#exit

if [ ${ENV} == "Production" ]; then
  if [ ${SEC_TIER} -eq 3 ]; then
    if [ ${REF_ARCH} == "Basic" ]; then
      createPublicVIP ${ENV}
    elif [ ${REF_ARCH} == "Standard" ]; then
      createSharedLB;
      createPools;
      updatePoolNodes;
    else
      echo "`date +"%c"`: No Reference Architecture has been found for Prod.. This shouldn't have happened!!"
    fi
  else
    createAlogicVIP;
    if [ ${REF_ARCH} == "Basic" ]; then
      createAlPublicVIP;
    elif [ ${REF_ARCH} == "Standard" ]; then
      createSharedLB;
      createPools;
      updateAlogicNodes;
    else
      echo "`date +"%c"`: No Reference Architecture has been found for Prod.. This shouldn't have happened!!"
    fi
  fi
elif [ ${ENV} == "Test" ]; then
   createPublicVIP ${ENV}
fi

# Cleanup
rm ./${SITE_ID}.json
