#!/bin/bash
SITE_ID="${1}"

json="{\"onlyChanged\":\"true\",\"applicationProcessId\":\"2f006501-60c9-4c84-8758-f4006999bf36\",\"snapshotId\":\"\",\"p_appID\":\"${SITE_ID}\",\"scheduleCheckbox\":false,\"description\":\"\",\"properties\":{\"appID\":\"${SITE_ID}\"},\"versions\":[],\"applicationId\":\"1a181fcd-fce2-4641-bec8-d217f431b1bf\",\"environmentId\":\"8dee5ff5-6a5c-49e4-b1fc-f869f90ee51b\"}"

process=`curl -s -u user:password -k -XPUT -H "Content-Type: application/json" -d "${json}" "https://206.128.154.113:8443/rest/deploy/application/1a181fcd-fce2-4641-bec8-d217f431b1bf/runProcess"`

id=`echo ${process} | jq -r .id 2> /dev/null`
if [ "${id}" != "" ]; then
  echo "Public Access Process has been run"
else
  echo "The API call has failed with the following error: ${process}"
  exit 1
fi
