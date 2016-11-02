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
#    middleware.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Run provisionCLCSite.py
#    Run create hieradata for each server
#    Run siteSvnCreate
#    Update Puppet Master
#
#### Changelog
#
##   2016.01.22 <kristen.crawford@centurylink.com>
## - Initial release
#
## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
ADD_DC="${3}"
if [ "${ADD_DC}" == "" ]; then
  DC=`jq -r .Datacenter ./${SITE_ID}.json`
else
  DC="${ADD_DC}"
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

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
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

    DC=`jq -r .Datacenter ./${SITE_ID}.json`
    REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
    SEC_TIER=`jq -r .SecurityTier ./${SITE_ID}.json`
    ALOGIC=`jq -r .Alertlogic ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi

  if [ ${ACCT} == "" ]; then
    echo "`date +"%c"`: The Production Alias is missing from ${SITE_ID}.json. Alogic build cannot be completed without this information. Please ensure create subaccount finished successfully and updated the site's json."
    exit 1
  fi

  if [ "${ALOGIC}" == "Requested" ]; then
    echo "`date +"%c"`: The Alertlogic appliance email request has already been sent to the noc.  Moving on..."
    exit
  fi
}

function getAlogicServers {
  # Check alogic total before creating any servers
  hardwareGroupID=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"Location\":\"${DC}\"}" | jq -r '.HardwareGroups[] | select(.Name=="'${SITE_ID}' - Production - DMZ") | .UUID'`
  getExisting=`curl -s "https://${ENDPOINT}/REST/Server/GetAllServers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCT}\",\"HardwareGroupUUID\":\"${hardwareGroupID}\",\"Location\":\"${DC}\"}"`
  existingServers=`echo ${getExisting} | jq '.Servers | length'`
  echo ${existingServers}
}

function createCSV {
  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  VLAN=`echo ${getNetworks} | jq -r '.[] | select(.name=="'${SITE_ID}' - Production - DMZ") | .description'`
  cp ./alogic ${SITE_ID}.CSV
  sed -i -e "s/DC\:/DC\:${DC}/g" ./${SITE_ID}.CSV
  sed -i -e "s/ACCT\:/ACCT\:${ACCT}/g" ./${SITE_ID}.CSV
  sed -i -e "s/VLAN\:/VLAN\:${VLAN}/g" ./${SITE_ID}.CSV
  sed -i -e "s/GROUP\:/GROUP\:${SITE_ID}\ \-\ Production\ \-\ DMZ/g" ./${SITE_ID}.CSV
  if [ "${REF_ARCH}" == "Basic" ]; then
    sed -i -e "s/HA\:/HA\:False/g" ./${SITE_ID}.CSV
    sed -i -e "s/2IP\:/2IP\:True/g" ./${SITE_ID}.CSV
  elif [ "${REF_ARCH}" == "Standard" ]; then
    sed -i -e "s/HA\:/HA\:True/g" ./${SITE_ID}.CSV
    sed -i -e "s/2IP\:/2IP\:False/g" ./${SITE_ID}.CSV
  else
    echo "No Reference Architecture Found! Bailing..."
    exit 1
  fi

}

function sendEmail {
  mutt -e "my_hdr From:adaptivesupport@centurylink.com" -s "Please import the Ecosystem Partner Template" -c kristen.crawford@centurylink.com support@t3n.zendesk.com tony.martin@centurylink.com -a ${SITE_ID}.CSV <  basicAlogicMail.txt
  if [ $? -eq 0 ]; then
    echo "`date +"%c"`: Email requesting NOC to setup Alogic appliances has been sent. Once it is completed, you can setup the public access"
    # Mark environment provisioned as completed in site json
    updateAlogic=`jq '. |= .+ {"Alertlogic": "Requested"}' ./${SITE_ID}.json`
    rm -rf ./${SITE_ID}.json
    echo ${updateAlogic} > ./${SITE_ID}.json
    updateOrchestrate;   
  else
    echo "`date +"%c"`: Email requesting NOC to setup Alogic appliances has not been sent! Please send it manually"
  fi
}

getAuth;
getSiteInfo;
found=$(getAlogicServers);
if [ ${found} -eq 0 ]; then
  createCSV;
  sendEmail;
  # cleanup
  rm ./${SITE_ID}.CSV
fi
