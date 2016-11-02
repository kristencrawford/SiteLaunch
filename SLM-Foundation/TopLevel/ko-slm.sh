#!/bin/bash

#
#      _____            _                    _     _       _      _____ _                 _ 
#     /  __ \          | |                  | |   (_)     | |    /  __ \ |               | |
#     | /  \/ ___ _ __ | |_ _   _ _ __ _   _| |    _ _ __ | | __ | /  \/ | ___  _   _  __| |
#     | |    / _ \ '_ \| __| | | | '__| | | | |   | | '_ \| |/ / | |   | |/ _ \| | | |/ _` |
#     | \__/\  __/ | | | |_| |_| | |  | |_| | |___| | | | |   <  | \__/\ | (_) | |_| | (_| |
#      \____/\___|_| |_|\__|\__,_|_|   \__, \_____/_|_| |_|_|\_\  \____/_|\___/ \__,_|\__,_|
#                                        __/ |                                               
#                                       |___/                                                
#
#
# Ken Weinreich - <ken.weinreich@centurylink.com>
# Kristen Crawford - <kristen.crawford@centurylink.com>

## Set variables configured in package.manifest
APPLICATION_ID="${1}"
CLC_ACCOUNT_ALIAS="${2}"
SERVICE_TIER="${3}"
SECURITY_TIER="${4}"
ENVIRONMENTS_REQUESTED="${5}"
DATACENTER="${6}"
REM_TEST="${7}"
SYN_TEST="${8}"
REF_ARCH="${9}"
SHIBBOLETH="${10}"
TECHSTACK="${11}"
APPLICATION_NAME="${12}"
PARENT_ALIAS="${13}"
FILESERVER="${14}"
MEMCACHED="${15}"
FIRST_NAME="${16}"
LAST_NAME="${17}"
EMAIL="${18}"
DEV_GROUP="${19}"
URL="${20}"
REM_PROD="${21}"
SYN_PROD="${22}"
DBAAS="${23}"
TEST_REQ_DATE="${24}"
PROD_REQ_DATE="${25}"

## Script Variables
TIMESTAMP=`date +%Y-%m-%d' '%H:%M:%S`

#NOTE# Orchestrate.io Information
APIKEY=""
ENDPOINT=""
COLLECTION=""

function updateOrchestrate
{
  JSON=`cat ./${APPLICATION_ID}.json`
  curl -is "https://${ENDPOINT}/v0/${COLLECTION}/${APPLICATION_ID}" -XPUT -H "Content-Type: application/json" -u "$APIKEY:" -d "${JSON}" -o /dev/null
  echo "${APPLICATION_ID}.json commited to Orchestrate"
}

function createSiteJSON
{
  getIndex=`curl -s "https://${ENDPOINT}/v0/${COLLECTION}/${APPLICATION_ID}" -XGET -H "Content-Type: application/json" -u "$APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .ApplicationID`
  if [ "${checkIndex}" == "${APPLICATION_ID}" ]; then
    echo $getIndex > ./${APPLICATION_ID}.json
    echo "${APPLICATION_ID}.json retrieved from Orchestrate"
  else
    cp ./site.json ./${APPLICATION_ID}.json
    echo "${APPLICATION_ID}.json created"
  fi

  if [ ! -f ./${APPLICATION_ID}.json ]; then
    echo "${APPLICATION_ID}.json was not created, please try again"
    exit 1
  fi
}

function updateProd
{
  if [[ "${REM_PROD}" == "" || "${SYN_PROD}" == "" || "${PROD_REQ_DATE}" == "" ]]; then
    echo "When Production is selected, you must enter the Prod Rememdy, Prod Synergy Ticket Number and Prod request date!! Please rerun Foundation with those entered."
    rm ./${APPLICATION_ID}.json
    exit 1
  fi
  sed -i -e "s/_ProdRequested_/True/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_CreateProdRRequestTicket_/${REM_PROD}/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_CreateProdSRequestTicket_/${SYN_PROD}/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_ProdRequest_/${PROD_REQ_DATE}/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_ProdBuildStart_/$TIMESTAMP/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_ProdSunsetRequestTicket_/NULL/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_ProdSunsetStart_/NULL/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_ProdSunsetComplete_/NULL/g" ./${APPLICATION_ID}.json #
}

function updateTest
{
  if [[ "${REM_TEST}" == "" || "${SYN_TEST}" == "" || "${TEST_REQ_DATE}" == "" ]]; then
    echo "When Test is selected, you must enter both the Test Rememdy, Test Synergy Ticket Number and Test request Date!! Please rerun Foundation with those entered."
    rm ./${APPLICATION_ID}.json
    exit 1
  fi
  sed -i -e "s/_TestRequested_/True/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_CreateTestRRequestTicket_/${REM_TEST}/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_CreateTestSRequestTicket_/${SYN_TEST}/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_TestRequest_/${TEST_REQ_DATE}/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_TestBuildStart_/$TIMESTAMP/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_TestSunsetRequestTicket_/NULL/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_TestSunsetStart_/NULL/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_TestSunsetComplete_/NULL/g" ./${APPLICATION_ID}.json #
}

function updateDev
{
  sed -i -e "s/_DevRequested_/True/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_CreateDevRRequestTicket_/$REMEDY_TICKET__/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_CreateDevSRequestTicket_/$SYNERGY_TICKET__/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_DevRequest_/$TIMESTAMP/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_DevBuildStart_/$TIMESTAMP/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_DevSunsetRequestTicket_/NULL/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_DevSunsetStart_/NULL/g" ./${APPLICATION_ID}.json #
  sed -i -e "s/_DevSunsetComplete_/NULL/g" ./${APPLICATION_ID}.json #
}


function updateJSON
{
  #NOTE# Basic Site Information
  sed -i -e "s/_ApplicationID_/$APPLICATION_ID/g" ./${APPLICATION_ID}.json #Application ID
  sed -i -e "s/_ApplicationName_/$APPLICATION_NAME/g" ./${APPLICATION_ID}.json #Application Name
  sed -i -e "s/_CLCAccountAlias_/$CLC_ACCOUNT_ALIAS/g" ./${APPLICATION_ID}.json #Sub Account Alias
  sed -i -e "s/_CLCParentAlias_/$PARENT_ALIAS/g" ./${APPLICATION_ID}.json #Sub Account's Parent Alias
  sed -i -e "s/_ServiceTier/$SERVICE_TIER/g" ./${APPLICATION_ID}.json #Support Tier
  sed -i -e "s/_TechStack_/$TECHSTACK/g" ./${APPLICATION_ID}.json #Tech Stack
  sed -i -e "s/_ReferenceArchitecture_/$REF_ARCH/g" ./${APPLICATION_ID}.json #Reference Architecture
  sed -i -e "s/_SecurityTier_/$SECURITY_TIER/g" ./${APPLICATION_ID}.json #Secrutiy Level

  sed -i -e "s/_Datacenter_/$DATACENTER/g" ./${APPLICATION_ID}.json #Datacenter
  sed -i -e "s/_Shibboleth_/$SHIBBOLETH/g" ./${APPLICATION_ID}.json #Shibboleth
  sed -i -e "s/_FS_/$FILESERVER/g" ./${APPLICATION_ID}.json # Filserver
  sed -i -e "s/_MemD_/$MEMCACHED/g" ./${APPLICATION_ID}.json # Memcached
  sed -i -e "s/_Group_/$DEV_GROUP/g" ./${APPLICATION_ID}.json # Group
  sed -i -e "s/_DbaaS_/$DBAAS/g" ./${APPLICATION_ID}.json # DbaaS

  if [ "${URL}" != "" ]; then
    updateURL=`jq '. |= .+ {"URL": "'${URL}'"}' ./${APPLICATION_ID}.json`
    rm -rf ./${APPLICATION_ID}.json
    echo ${updateURL} > ./${APPLICATION_ID}.json
  fi

  #NOTE# Environment Information
  #NOTE# I doubt this is the most efficient way to do any of this, but yolo
  #NOTE# Fix this logic later, idiot
  NUMENV=`echo $ENVIRONMENTS_REQUESTED | awk -F "," '{print NF-1}'`
  if [ $NUMENV = "0" ]; then
    ENV1=`echo $ENVIRONMENTS_REQUESTED`
    if [ $ENV1 = "Production" ]; then
      updateProd;
    fi

    if [ $ENV1 = "Test" ]; then
      updateTest;
    fi

    if [ $ENV1 = "Dev" ]; then
      updateDev;
    fi
  elif [ $NUMENV = "1" ]; then
    ENV1=`echo $ENVIRONMENTS_REQUESTED | awk -F "," '{print $1}'`
    ENV2=`echo $ENVIRONMENTS_REQUESTED | awk -F "," '{print $2}'`

    if [ $ENV1 = "Production" ] || [ $ENV2 = "Production" ]; then
      updateProd;
    fi

    if [ $ENV1 = "Test" ] || [ $ENV2 = "Test" ]; then
      updateTest;
    fi

    if [ $ENV1 = "Dev" ] || [ $ENV2 = "Dev" ]; then
      updateDev;
    fi
  elif [ $NUMENV = "2" ]; then
    ENV1=`echo $ENVIRONMENTS_REQUESTED | awk -F "," '{print $1}'` #NOTE# Should always be Dev
    ENV2=`echo $ENVIRONMENTS_REQUESTED | awk -F "," '{print $2}'` #NOTE# Should always be Test
    ENV3=`echo $ENVIRONMENTS_REQUESTED | awk -F "," '{print $3}'` #NOTE# Should always be Production
    updateProd;
    updateTest;
    updateDev;
  fi

}

function updateRequestor {
  filter="jq '.Requestors[] | select(.FirstName==\"${FIRST_NAME}\") | select(.LastName==\"${LAST_NAME}\")'"
  requestor_found=`eval ${filter} ./${APPLICATION_ID}.json`
  if [ -z "${requestor_found}" ]; then
    total=$(jq '.Requestors[] | length' ./${APPLICATION_ID}.json | wc -l)
    putFilter="jq '.Requestors['${total}'] |= .+ { "FirstName" : \"${FIRST_NAME}\","LastName" : \"${LAST_NAME}\","Email" : \"${EMAIL}\","Access" : \"_NewUser_\" }'"
    newJSON=$(eval ${putFilter} ./${APPLICATION_ID}.json)
    if [ "${?}" != "0" ]; then
      exit 1
    fi
    rm -rf ./${APPLICATION_ID}.json
    echo ${newJSON} > ./${APPLICATION_ID}.json
  fi
}

#Do the things!
#debugInputs;
# Verify inputs where possible..Some of the checking will be done by the package itself in CLC
# Site IDs must be numeric
TEST=`echo ${APPLICATION_ID} | grep '^[0-9][0-9][0-9][0-9][0-9][0-9]$' 2> /dev/null`
if [ "${APPLICATION_ID}" != "$TEST" ]; then
  echo "Invalid site ID."
  exit 1
fi

# Account ID must be K###
TEST2=`echo ${CLC_ACCOUNT_ALIAS} | grep '^K[A-F0-9][A-F0-9][A-F0-9]$' 2> /dev/null`
if [ "${CLC_ACCOUNT_ALIAS}" != "$TEST2" ]; then
  echo "Invalid Account ID."
  exit 1
fi

createSiteJSON;
updateJSON;
updateRequestor;
updateOrchestrate;

# Cleanup
rm ./${APPLICATION_ID}.json
