#!/usr/bin/env bash

PREFIX="ansibleautomationmananger"
REDIS="redis-cli"
AWX='awx'

vl status|awk '{ print $2".openknowit.com" }'	 > /tmp/vlinventory.ini

###############################################################################################################
# Save status to redis
###############################################################################################################
for list in credential_types inventory hosts credential organizations users execution_environments projects
do
    echo "`date`: $list"
    ${AWX} ${list} list|jq ".results[]  | {"id": .id, "name": .name}" -c 2>/dev/null >/tmp/$$.$list
    for item in `cat /tmp/$$.$list |tr ' ' '#' `
    do
       # echo "`date`: $item"
        ID=`echo $item |jq .id`
        RAWNAME=`echo $item |jq .name | tr '#' '_' |tr -d '"' `
        NAME=`echo $item |jq .name | tr '#' ' ' |tr -d '"' `
        KEY="${PREFIX}:${list}:id:${ID}"
        ${REDIS} set $KEY "$NAME" ex 6000 >/dev/null 2>&1
        KEY="${PREFIX}:${list}:name:${RAWNAME}"
        ${REDIS} set  $KEY $ID ex 6000 >/dev/null 2>&1
    done
done

###############################################################################################################
#  Create organizations
#######################A########################################################################################
echo "`date`: Create organizations"
${REDIS} keys "*"  |grep ansibleautomationmananger:organizations:name | awk -F"ansibleautomationmananger:organizations:name:" '{ print $2 }'  > /tmp/$$.organizations.list 2>/dev/null

for org in `cat demo.json | jq .organization[].name -r | tr ' ' '_'`
do
    JSON=`cat demo.json | jq ' .organization[]  | {"name": .name , "description": .description , "max_hosts": .max_hosts , "default_environment": .default_environment }' -c  |tr ' ' '_'  |grep $org`
    echo "$JSON"
    NAME=`echo $JSON | jq .name -r | tr '_' ' '`
    DESC=`echo $JSON | jq .description -r | tr '_' ' '`
    EENAME=`echo $JSON | jq .default_environment -r | tr ' ' '_'`
    MH=`echo $JSON | jq .max_hosts -r`
    EEID=`${REDIS} get "ansibleautomationmananger:execution_environments:name:${EENAME}" |tr -d '"'`
    echo "`date`: $EEID  :    $EENAME"
    ${AWX} organization create --name "${NAME}"  >/dev/null 2>&1
    myid=`${AWX} organizations list --name "${NAME}"|jq ".results[].id"`
    echo "`date`: The org $org has mow the id $myid"
    ${AWX} organization modify $myid --name "${NAME}" --description "${DESC}" --default_environment $EEID --max_hosts $MH  >/dev/null 2>&1
    sed -i "s/^$org$//" /tmp/$$.organizations.list
done




echo "`date`: Cleanup orphan organizations"
###############################################################################################################
# Save status to redis
###############################################################################################################
for orphanorg in `cat /tmp/$$.organizations.list | grep -i [a-z] |tr ' ' '_'`
do
    echo "`date`: $orphanorg"
    KEY="${PREFIX}:organizations:name:${orphanorg}"
    ORGID=`${REDIS} get $KEY 2>/dev/null`
    if [[ $? == 0 ]];
    then
        ${AWX} organization delete $ORGID
    fi
    ${REDIS} del $KEY >/dev/null 2>&1
done
rm /tmp/$$.organizations.list



for orgid in `cat demo.json | jq ".organization| keys[]"`
do
        ${REDIS} keys "*"  |grep ansibleautomationmananger:credentials:name | awk -F"ansibleautomationmananger:credentials:name:" '{ print $2 }'  > /tmp/$$.credentials.list
        org=`cat demo.json | jq ".organization[$orgid].name" -r`
        ###############################################################################################################
        #  Create Credentials
        ###############################################################################################################
        echo "`date`: Create credentials for organization $org"
        for credential  in `cat demo.json | jq .organization[$orgid].credentials[].name -r`
        do
           echo "`date`: Credential : $credential"
           JSON=`cat demo.json | jq .organization[$orgid].credentials[]| jq '. | {"name": .name , "description": .description , "credential_type": .credential_type , "ssh_key_file": .ssh_key_file , "kind": .kind , "user": .user , "password": .password }' -c  |  grep "\"${credential}\""`
    	   echo "$JSON"
           NAME=`echo $JSON | jq .name -r `
           DESC=`echo $JSON | jq .description -r | tr '_' ' '`
           TYPE=`echo $JSON | jq .credential_type -r | tr '_' ' '`
           USER=`echo $JSON | jq .user -r | tr '_' ' '`
           PASW=`echo $JSON | jq .password -r | tr '_' ' '`
           KIND=`echo $JSON | jq .kind -r | tr '_' ' '`
           ${AWX} credential create --name "${NAME}" --description "${DESC}"  --credential_type "${TYPE}" --organization "${org}"
           myid=`${AWX} credentials list --name "${NAME}"|jq ".results[].id"`
           echo "`date`: The credential $credential has mow the id $myid"
	   INPUTS="$(jq -R -s '{"username":"'"${USER}"'","ssh_key_data":.}' < ~/.ssh/id_rsa)"
           ${AWX} credential modify $myid --inputs "${INPUTS}"
           sed -i "s/^$NAME$//" /tmp/$$.credentials.list

        done
        ###############################################################################################################
        #  Create Master inventory  for the Organisation
        ###############################################################################################################
        echo "`date`: Inventories"
        for inventory  in `cat demo.json | jq .organization[$orgid].inventories[].name -r`
        do
           JSON=`cat demo.json | jq .organization[$orgid].inventories[]| jq '. | {"name": .name , "description": .description , "hosts": .hosts , "credential": .credential }' -c  |  grep "\"${inventory}\""`
    	   echo "$JSON"
           NAME=`echo $JSON | jq .name -r `
           DESC=`echo $JSON | jq .description -r | tr '_' ' '`
           HOSTSLIST=`echo $JSON | jq .hosts -r`
           CREDENTIAL=`echo $JSON | jq .credential -r`
           echo "`date`: create inventory : $HOSTSLIST"
           ${AWX} inventory create --name "$NAME" --organization "$org" --description "$DESC"
        #   INPUTS="{\"username\": \"root\",\"ssh_key_data\": \"`cat ~/.ssh/id_rsa`\"}"
        #   ${AWX} credential create --name "${NAME}" --description "${DESC}"  --credential_type "Machine" --organization "${org}"
       #    myid=`${AWX} credentials list --name "${CREDENTIAL}"|jq ".results[].id"`
       #    ${AWX} credential modify $myid --name "${NAME}" --description "${DESC}"  --credential_type "Machine" --organization "${org}" --inputs "${INPUTS}"

           for invhost in  `cat ${HOSTSLIST}`
           do
                INPUTS="{\"username\": \"\",\"ssh_key_data\": \"`cat ~/.ssh/id_rsa`\"}"
                ${AWX} host create --name "$invhost" --inventory "$NAME"
                #${AWX} credential create --name "${invhost}" --description "${DESC}"  --credential_type "Machine" --organization "${org}" --inputs "${INPUTS}"
           done
        done
        ###############################################################################################################
        #  Create projects
        #######################A########################################################################################
        echo "`date`: Create projects"
        ${REDIS} keys "*"  |grep ansibleautomationmananger:projects:name | awk -F"ansibleautomationmananger:projects:name:" '{ print $2 }'  > /tmp/$$.projects.list
        for project in `cat demo.json | jq .organization[].projects[].name -r`
        do
            echo "`date`: Project : $project"
            JSON=`cat demo.json | jq ' .organization[].projects[]  | {"name": .name , "description": .description , "scm_type": .scm_type , "scm_url": .scm_url, "scm_branch": .scm_branch, "credential": .credential , "master": .master }' -c  |  grep "\"${project}\""`
    	    echo "$JSON"
            echo "`date`: $JSON"
            NAME=`echo $JSON | jq .name -r `
            DESC=`echo $JSON | jq .description -r `
            SCM_TYPE=`echo $JSON | jq .scm_type -r  `
            SCM_URL=`echo $JSON | jq .scm_url -r `
            SCM_BRANCH=`echo $JSON | jq .scm_branch -r `
            CREDENTIAL=`echo $JSON | jq .credential -r `
            MASTER=`echo $JSON | jq .master -r `
            mycredid=`${AWX} credentials list --name "${CREDENTIAL}" |jq ".results[].id" -r`
            echo "`date`: Credintial id is $mycredid"
            ${AWX} projects create --name "${NAME}" --description "${DESC}"  --credential $mycredid --organization "$org"
            myid=`${AWX} projects list --name "${NAME}"|jq ".results[].id" -r `
            echo "`date`: The project $project has now the id $myid"
            ${AWX} projects modify $myid --name "${NAME}" --description "${DESC}" --scm_type "${SCM_TYPE}" --scm_url "${SCM_URL}"  --scm_branch "${SCM_BRANCH}" --credential $mycredid --organization "$org"
            sed -i "s/^$org$//" /tmp/$$.projects.list
        done

        ###############################################################################################################
        #  Orphan projects
        #######################A########################################################################################
        cat /tmp/$$.projects.list






done
exit
#          "name": "ansibleautomation",
#          "description": "Main project ensure automation engine consistency",
#          "scm_type": "Git",
#          "scm_url": "https://git2.it.rm.dk:3000/jho/ansibleautomation.git",
#          "credential": "github",
#          "master": "True"
#

#               "scm_type": "git",
#               "scm_url": "https://git2.it.rm.dk:3000/jho/ansibleautomation.git",
#              "scm_branch": "main",
#              "scm_refspec": "",
#              "scm_clean": false,
#              "scm_track_submodules": false,
#               "scm_delete_on_update": false,
#               "credential": 42,
#               "timeout": 0,
#               "scm_revision": "2f69a37fd73348b4b525019b4ec00c7dc8cdf143",
##               "last_job_run": "2022-11-21T13:14:23.689996Z",
#               "last_job_failed": false,
#               "next_job_run": null,
#               "status": "successful",
#               "organization": 5,
#               "scm_update_on_launch": false,
##               "scm_update_cache_timeout": 0,
[jho@exrhel0284 openknowit_ansible_feed-main]$


















































































