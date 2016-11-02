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
#    Blueprint package install.sh template generated via:
#    http://centurylinkcloud.github.io/Ecosystem/BlueprintManifestBuilder/
#
#    addUser.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Add new users and groups to Active Directory and the CLC Portal
#
#### Changelog
#
##   2015.11.06 <kristen.crawford@centurylink.com>
## - Initial release


## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ADD_DC="${2}"

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
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    GET_ENV=`jq -r '.Environments[] | select(.Requested=="True") | .Name' ./${SITE_ID}.json`
    ENV=`echo -n "$GET_ENV"|tr '\n' ','`
    ALOGIC=`jq -r .SecurityTier ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
    email="no"
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}


function renameDefNetwork {
  ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi
  # Ensure a default network exists
  getNetCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
  if [ "${getNetCount}" -eq "1" ]; then
    getDefNet=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
    netID=`echo ${getDefNet} | jq -r '.[] | .id'`
    defName=`echo ${getDefNet} | jq -r '.[] | .name'`
    if [ "${defName}" != "${SITE_ID} - ${1} - Web" ]; then
      rename=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}/${netID}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPUT -H "Content-type: application/json" -d "{\"name\": \"${SITE_ID} - ${1} - Web\",\"description\":\"${defName}\"}"`
      if [ "$?" != "0" ]; then
        echo "`date +"%c"`: Default network rename failed!"
      fi
    fi
  elif [[ "${getNetCount}" -eq "0" && "${ADD_DC}" == "" ]]; then
    echo "`date +"%c"`: Default Network was not created! Go figure out why and rerun once the default network exists.  Bailing..."
    exit 1
  fi
}

function createNetworks {
  neededNetworks="1"
  ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  if [ "${DBAAS}" == "false" ]; then
    neededNetworks=$(( neededNetworks + 1 ))
  fi

  if [ ${1} == "Production" ]; then
    if [[ ${ALOGIC} = "1" || ${ALOGIC} = "2" ]]; then
      neededNetworks=$(( neededNetworks + 1 ))
    fi
  fi

  timer="0"
  while true; do
    unset claim requestID getStatus
    getNetworkCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
    if [ ${getNetworkCount} -lt ${neededNetworks} ]; then
      claim=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}/claim" -d -XPOST -H "Authorization: Bearer ${TOKEN}"`
      vpnCheck=`echo ${claim} | jq -r .message`
      if [ "${vpnCheck}" != "null" ]; then
        echo "`date +"%c"`: ${ACCT} cannot create new networks, most likely because of a vpn server failure.  An email will be sent to the NOC with the failure.  Once it is resolved please try again."
        cat vpnFailure.txt | sed s/ACCT/${ACCT}/g > ./${ACCT}.txt
        mutt -e "my_hdr From:adaptivesupport@centurylink.com" -s "Failed VPN Server in Alias: ${ACCT}" -c kristen.crawford@centurylink.com support@t3n.zendesk.com adaptivesupport@centurylink.com < ./${ACCT}.txt
	email="yes"
	rm ./${ACCT}.txt
	break
      else
        requestURI=`echo ${claim} | jq -r '.uri'`
      fi
      getStatus=`curl -s "https://${ENDPOINT}/${requestURI} " -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
      timer2="0"
      while [ "${getStatus}" != "succeeded" ]; do
        echo "`date +"%c"`: Network creation ${getStatus} for ${ACCT}..."
        sleep 30
        getStatus=`curl -s "https://${ENDPOINT}/${requestURI} " -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
	if [ "${getStatus}" == "failed" ]; then
    	  break
	fi
	timer2=$(( timer2 + 1));
        if [ ${timer2} -eq 10 ]; then
          break
        fi
      done
      if [ "${getStatus}" != "failed" ]; then
        newNetworkCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
        echo "`date +"%c"`: Network #${newNetworkCount} created for ${ACCT}"
      else
        echo "`date +"%c"`: Network creation failed for ${ACCT}, trying again! "
      fi
    else
      # Break out of while as we are done adding networks
      echo "`date +"%c"`: Network creation is complete for ${SITE_ID} - ${1}"
      break
    fi
    timer=$(( timer + 1));
    if [ "${timer}" == 10 ]; then
      exit 1
    fi
  done
   
}

function renameNetworks {
  ## Determine if test db network has to be named
  ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  netCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
  web="unset"
  if [ ${DBAAS} == "true" ]; then
    db="set"
  else
    db="unset"
  fi
  for (( i = 0 ; i < ${netCount} ; i++ )); do
    networkName=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" |  jq -r '.['${i}'] | .name'`
    if [ "${networkName}" == "${SITE_ID} - ${1} - DB" ]; then
      db="set"
    elif [ "${networkName}" == "${SITE_ID} - ${1} - Web" ]; then
      web="set"
    fi
  done

  if [[ ${web} == "unset" && "${ADD_DC}" == "" ]]; then
    echo "Default Network has not been renamed to ${1} Web.  Go figure out why and then rerun.  Bailing..."
    exit 1
  else 
    getNets=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
    netID=`echo ${getNets} | jq -r '.[1] | .id'`
    netName=`echo ${getNets} | jq -r '.[1] | .name'`
    if [ "${netName}" != "${SITE_ID} - ${1} - Web" ]; then
      rename=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}/${netID}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPUT -H "Content-type: application/json" -d "{\"name\": \"${SITE_ID} - ${1} - Web\",\"description\":\"${netName}\"}"`
      if [ "$?" != "0" ]; then
        echo "`date +"%c"`: ${1} Web network rename failed!"
      fi
    fi
  fi

  if [ ${db} == "unset" ]; then
    for (( i = 0 ; i < $netCount ; i++ )); do
      networkID=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.['${i}'] | .id'`
      networkName=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" |  jq -r '.['${i}'] | .name'`
      if [[ "${networkName}" =~ "${SITE_ID} - ${1}" ]]; then
        #If network name is already changed, move on
        continue
      else
        renameDB=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}/${networkID}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPUT -H "Content-type: application/json" -d "{\"name\": \"${SITE_ID} - ${1} - DB\",\"description\":\"${networkName}\"}"`
        
        if [ "$?" == "0" ]; then
          break #Breat out of 'for loop' since we only have to rename one network
        fi
      fi
    done
  fi
}

function renameDMZNetwork {
  ACCT=`jq -r '.Environments[] | select(.Name=="Production") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  ## Determine if dmz network has to be named
  dmzNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
  dmz="unset"
  for (( i = 0 ; i < $dmzNetworks ; i++ )); do
    networkName=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" |  jq -r '.['${i}'] | .name'`
    if [ "${networkName}" == "${SITE_ID} - Production - DMZ" ]; then
      dmz="set"
      break
    fi
  done

  # Create Prod DMZ Net if not set
  if [ "${dmz}" == "unset" ]; then
    for (( i = 0 ; i < $dmzNetworks ; i++ )); do
      networkID=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r '.['${i}'] | .id'`
      networkName=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" |  jq -r '.['${i}'] | .name'`
      if [[ "${networkName}" =~ "${SITE_ID} - Production" ]]; then
        #If network name already changed for web network, move on
        continue
      else
        renameProdDMZ=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}/${networkID}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPUT -H "Content-type: application/json" -d "{\"name\": \"${SITE_ID} - Production - DMZ\",\"description\":\"${networkName}\"}"`
        if [ "$?" == "0" ]; then
          #Once verified that the network was renamed for prod web, break out of for loop
          break
        fi
      fi
    done
  fi
}

function horizontalPolicy {
  ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  policyCheck=`curl -s "https://${ENDPOINT}/v2/horizontalAutoscalePolicies/${ACCT}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq .items[]`
  if [ -z ${policyCheck} ]; then
    hsPolicyJSON="{\"coolDownPeriod\":\"00:15:00\",\"id\":null,\"minimumServerCount\":1,\"name\":\"${SITE_ID} Scale Policy\",\"scaleIn\":{\"cpuPercentThreshold\":20,\"memoryPercentThreshold\":20,\"scaleBy\":1},\"scaleOut\":{\"cpuPercentThreshold\":80,\"memoryPercentThreshold\":80,\"scaleBy\":1},\"thresholdPeriod\":\"00:15:00\"}"
    addPolicy=`curl -s "https://${ENDPOINT}/v2/horizontalAutoscalePolicies/${ACCT}" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "${hsPolicyJSON}"`
    policyName=`echo ${addPolicy} | jq .name`
    echo "`date +"%c"`: Horizontal Scale Policy ${policyName} has been created ${SITE_ID} - ${1}"
  else
    echo "`date +"%c"`: Horizontal Scale Policy already exists for ${SITE_ID} - ${1}, Moving on.."
  fi
}


## Main ##
#get auth credentials for api 1 and 2
getAuth;
getSiteInfo;

# Call Create networks no matter what, even if some networks are created it will take that into account
NUMENV=`echo $ENV | awk -F "," '{print NF-1}'`
NUMENV=$(( NUMENV + 1 ))
for (( j = 1 ; j <= ${NUMENV} ; j++ )); do
  unset currentEnv
  currentEnv=`echo $ENV | awk -F "," '{print $'$j'}'`
  renameDefNetwork "${currentEnv}"
  createNetworks "${currentEnv}"
  renameNetworks "${currentEnv}"
  horizontalPolicy "${currentEnv}"
  if [ "${currentEnv}" == "Production" ]; then
    if [[ ${ALOGIC} = "1" || ${ALOGIC} = "2" ]]; then
      renameDMZNetwork;
    fi
  fi
done

# cleanup
rm ./${SITE_ID}.json
if [ "${email}" == "yes" ]; then
  exit 1
fi
