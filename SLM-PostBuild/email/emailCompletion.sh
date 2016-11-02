## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"

#NOTE# Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Ensure jq is installed
if [ ! `rpm -qa | grep jq-` ]; then
  yum install jq -y
fi

function getSiteInfo {
  getIndex=`curl -s "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XGET -H "Content-Type: application/json" -u "$ORCH_APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .code`

  if [ "$checkIndex" != "items_not_found" ]; then
    echo $getIndex > ./${SITE_ID}.json
    #ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
    DC=`jq -r .Datacenter ./${SITE_ID}.json`
    SERVICE_TIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
    SEC_TIER=`jq -r .SecurityTier ./${SITE_ID}.json`
    APP_NAME=`jq -r .ApplicationName ./${SITE_ID}.json`
    FIRST_NAME=`jq -r '.Requestors[] | .FirstName' ./${SITE_ID}.json`
    LAST_NAME=`jq -r '.Requestors[] | .LastName' ./${SITE_ID}.json`
    EMAIL_ADDRESS=`jq -r '.Requestors[] | .Email' ./${SITE_ID}.json`
    GROUP=`jq -r .SiteGroup ./${SITE_ID}.json`
    USERNAME=`echo ${FIRST_NAME:0:1}${LAST_NAME} | awk '{print tolower($0)}'`
    VIP=`jq -r .VIP ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function createEmail {
  cp ./email_3.html ./${SITE_ID}.html
  sed -i -e "s/__siteID__/${SITE_ID}/g" ./${SITE_ID}.html
  sed -i -e "s/__siteName__/${APP_NAME}/g" ./${SITE_ID}.html
  sed -i -e "s/__refArch__/${REF_ARCH}/g" ./${SITE_ID}.html
  sed -i -e "s/__metal__/${SERVICE_TIER}/g" ./${SITE_ID}.html
  sed -i -e "s/__secTier__/${SEC_TIER}/g" ./${SITE_ID}.html
  sed -i -e "s/__dc__/${DC}/g" ./${SITE_ID}.html
  sed -i -e "s/__First__/${FIRST_NAME}/g" ./${SITE_ID}.html
  sed -i -e "s/__Last__/${LAST_NAME}/g" ./${SITE_ID}.html
  sed -i -e "s/__user__/${USERNAME}/g" ./${SITE_ID}.html
  sed -i -e "s/__agency__/${GROUP}/g" ./${SITE_ID}.html
  sed -i -e "s/__env__/${ENV}/g" ./${SITE_ID}.html
  sed -i -e "s/__VIP__/${VIP}/g" ./${SITE_ID}.html
  if [ "${DC}" == "VA1" ]; then
    splunkVIP="206.128.156.157"
  elif [ "${DC}" == "GB3" ]; then
    splunkVIP="206.142.241.31"
  elif [ "${DC}" == "UC1" ]; then
    splunkVIP="64.15.186.18"
  elif [ "${DC}" == "SG1" ]; then
    splunkVIP="205.139.16.54"
  fi
  sed -i -e "s/__splunk__/${splunkVIP}/g" ./${SITE_ID}.html
}

getSiteInfo;
createEmail;
mail -s "$(echo -e "New Site Delivery - ${SITE_ID} - ${APP_NAME}; ${ENV};\nContent-Type: text/html")"  your_email  <  ./${SITE_ID}.html

