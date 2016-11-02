#!/bin/bash
## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
PRIM_TERR="${2}"
PII="${3}"
# Verify who is running the script so you know which db to use.  Root writes to Test and udeploy writes to Prod (through udeploy)
user=`whoami`
if [ "${user}" == "root" ]; then
  db="Test"
elif [ "${user}" == "udeploy" ]; then
  db="Prod"
else
  echo "`date +"%c"`: ${user} is not authorized to update slimdb! Please use udeploy user (via udeploy)"
fi

#NOTE# Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

function getSiteInfo {
  getIndex=`curl -s "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XGET -H "Content-Type: application/json" -u "$ORCH_APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .code`

  if [ "$checkIndex" != "items_not_found" ]; then
    echo $getIndex > ./${SITE_ID}.json
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
    DC=`jq -r .Datacenter ./${SITE_ID}.json`
    SERVICE_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    STACK=`jq -r .TechStack ./${SITE_ID}.json`
    PARENT=`jq -r .CLCParentAlias ./${SITE_ID}.json`
    BAN_ID=`mysql -e "USE SLIMDB_${db}; SELECT banID FROM bans WHERE company='${PARENT}';" | grep -v banID`
    SHIB=`jq -r .Shibboleth ./${SITE_ID}.json`
    REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
    SEC_TIER=`jq -r .SecurityTier ./${SITE_ID}.json`
    APP_NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
    AGENCY=`jq -r .SiteGroup ./${SITE_ID}.json`
    FNAME=`jq -r '.Requestors[0] | .FirstName' ./${SITE_ID}.json`
    LNAME=`jq -r '.Requestors[0] | .LastName' ./${SITE_ID}.json`
    EMAIL=`jq -r '.Requestors[0] | .Email' ./${SITE_ID}.json`
    GET_ENV=`jq -r '.Environments[] | select(.Requested=="True") | .Name' ./${SITE_ID}.json`
    ENV=`echo -n "$GET_ENV"|tr '\n' ','`
    URL=`jq -r .URL ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function updateSiteDB {
  REM_TICKET=`jq -r '.Environments[] | select(.Name=="'${1}'") | .RemedyRequest' ./${SITE_ID}.json`
  SYN_TICKET=`jq -r '.Environments[] | select(.Name=="'${1}'") | .SynergyRequest' ./${SITE_ID}.json`
  REQUEST_DATE=`jq -r '.Environments[] | select(.Name=="'${1}'") | .RequestDate' ./${SITE_ID}.json`
  ACCEPT_DATE=`jq -r '.Environments[] | select(.Name=="'${1}'") | .BuildStart' ./${SITE_ID}.json`
  unset ENV_ID
  unset siteCheck
  if [ "${1}" == "Production" ]; then
    ENV_ID="${SITE_ID}-00"
  elif [ "${1}" == "Test" ]; then
    ENV_ID="${SITE_ID}-01"
  elif [ "${1}" == "Dev" ]; then
    ENV_ID="${SITE_ID}-02"
  else
    echo "`date +"%c"`: No environment found, this shouldn't have happened!  Go see why and try again.."
    exit 1
  fi

  if [ "${STACK}" == "IIS" ]; then
    STACK=".Net"
  fi

  siteCheck=`mysql -e "SELECT siteID FROM SLIMDB_${db}.sites WHERE siteID='${ENV_ID}';" | grep -v siteID`
  if [ "${siteCheck}" == "${ENV_ID}" ]; then
    echo "`date +"%c"`: ${SITE_ID} has already been added to Slim DB. Moving on .."
  else
    insertSite=`mysql -e "INSERT INTO SLIMDB_${db}.sites (siteId,siteName,synergyAppId,siteStatus,banID,hostProvider,remedyTicket,synergyTicket,dataCenter,saml,techStack,dbms,secTier,infrTier,supTier,agencyName,reqFName,reqLName,reqEmail,requestDate,acceptDate,primaryTerritory,pii) VALUES('${ENV_ID}','${APP_NAME}','${SITE_ID}','In progress','${BAN_ID}','CTL','${REM_TICKET}','${SYN_TICKET}','${DC}','${SHIB}','${STACK}','${DBAAS}','${SEC_TIER}','${REF_ARCH}','${SERVICE_TIER}','${AGENCY}','${FNAME}','${LNAME}','${EMAIL}','${REQUEST_DATE}','${ACCEPT_DATE}','${PRIM_TERR}','${PII}');" 2>&1`
    if [ "${insertSite}" == "" ]; then
      echo "`date +"%c"`: New Site ${SITE_ID} entry has been added to the SLIM Database for ${1}"
    else
      echo "`date +"%c"`: New Site ${SITE_ID} was not added to the slim db. Error: ${insertSite}"
      exit 1
    fi
  fi

  if [[ "${URL}" != "null" && "${1}" == "Production" ]]; then
    updateURLDB ${ENV_ID};
  fi
}

function updateURLDB {
  urlCheck=`mysql -e "SELECT urls FROM SLIMDB_${db}.siteUrls WHERE urls='${URL}';" | grep -v urls`
  if [ "${urlCheck}" == "${URL}" ]; then
    echo "`date +"%c"`: ${URL} has already been added to Slim DB. Moving on .."
    rm ./${SITE_ID}.json
    exit 0
  else
    insertURL=`mysql -e "INSERT INTO SLIMDB_${db}.siteUrls (urls,siteId) VALUES('${URL}','${1}');" 2>&1`
    if [ "${insertURL}" == "" ]; then
      echo "`date +"%c"`: New URL ${URL} has been added to the SLIM Database for ${SITE_ID}"
    else
      echo "`date +"%c"`: New URL ${URL} was not added to the slim db. Error: ${insertURL}"
      exit 1
    fi
  fi
}

getSiteInfo;
NUMENV=`echo $ENV | awk -F "," '{print NF-1}'`
NUMENV=$(( NUMENV + 1 ))
for (( i = 1 ; i <= ${NUMENV} ; i++ )); do
  currentEnv=`echo $ENV | awk -F "," '{print $'$i'}'`
  updateSiteDB ${currentEnv}
done

#cleanup
rm ./${SITE_ID}.json
