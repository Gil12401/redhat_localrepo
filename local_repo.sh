#!/bin/bash

# 환경변수 Backup 
PRE_IFS=$IFS

# ***** 설정 파일 작명 규칙 : version_local.repo  *****
# local_repo.tar.gz -> centOS7_local.repo / centOS8_local.repo 
# local_repo_kvarray[centOS7]="centOS7_local.repo" / local_repo_kvarray[centOS8]="centOS8_local.repo"

declare -A local_repo_kvarray 
centOS_local_repos=($(tar -xvzf $(find / -name "local_repo.tar.gz" 2> /dev/null))) 
local_repo_file=""

for value in ${centOS_local_repos[@]}; do
    key=$(echo ${value} | cut -d '_' -f 1)
    local_repo_kvarray[${key}]=${value}
done

# 0. 현재 리눅스 버전에 맞는 설정파일 가져오기 : '/etc/*release'
eval "$(bash /util/file_to_map.sh '/etc/*release')" 
version_id=$(echo "${map["VERSION_ID"]}")
version_id=$(printf "%.0f" "${version_id}") # 버전에서 소숫점 제거 ( 내림 )

# 사용자에게 OS 버전 표기 
echo "----------------------------------------------"
echo " OS version : $(cat /etc/redhat-release)."
echo "----------------------------------------------"

if [[ ${version_id} -le 7 ]]; then 
    local_repo_file=${local_repo_kvarray["centOS7"]}
elif [[ ${version_id} -gt 7 ]]; then 
    local_repo_file=${local_repo_kvarray["centOS8"]}
fi

echo "------ Write the name of directory copied from /mnt ------" 
read dirname 
dirpath="$(pwd dirname)${dirname}"

# 1. OS ISO file mount at /mnt
# feedback 1 : sr0를 항상 표현할 수 있는 다른 방법 찾아보기 ( ex. symbolic link -> cdrom )
echo "1. OS ISO file mount at /mnt"
mount /dev/sr0 /mnt

# 2. make /dirname and copy all values from /mnt ( at Root Directory )
echo "2. make /dirname and copy all values from /mnt ( at Root Directory )"
cd /
mkdir -p ${dirpath}
cp -rv /mnt/* "${dirpath}"

# 3. Back up existing .repo file at /etc/yum.repos.d/
echo "3. Back up existing .repo file at /etc/yum.repos.d/"
cd /etc/yum.repos.d/
mkdir -p bak
mv * bak 

# 최상위 디렉토리 /로 경로를 다시 이동해주지 않으면 ${local_repo_file} 단독 사용으로 파일 찾을 수 없음. 
cd / 

# 4. Write /etc/yum.repos.d/local.repo 
echo "4. Write /etc/yum.repos.d/local.repo"

# Delimiter : "/" , last Token Package 제거
declare -A baseurl_kvarray
value_head="file://" 
value_tails=$(find ${dirpath} -name "Packages")

echo "making baseurl_kvarray ... "

for value_tail in ${value_tails[@]}; do

    key=""
    value=""

    # baseurl_kvarray value
    value_tail=$(echo ${value_tail} | sed "s/"Packages"//g") # Packages 문자열 제거 
    value="baseurl=${value_head}${value_tail}"

    # echo "value_tail : ${value_tail}"
   
    # baseurl_kvarray key -> Packages 디렉토리의 부모 디렉토리 ( ex. BaseOS, AppStream ) 
    IFS="/" 
    if [[ -n "${value_tail}" ]]; then
        for word in ${value_tail}; do
            if [[ ${word} == "Packages" ]]; then
                break
            fi
            key="${word}"
        done
    else
        true
    fi
    IFS=${PRE_IFS} # IFS Back up 

    # 7버전 이하 : /dvd/Packages ( AppStream, BaseOS 존재 X )
    if [[ "${key}" == *"AppStream"* || "${key}" == *"BaseOS"* ]]; then
        true
    else
        section=$(cat ${local_repo_file} | grep "^\[.*]$")
        key=$(echo ${section} | cut -d "-" -f 2 | tr -d "[-]"])
    fi

    echo "baseurl_kvarray key : ${key}"
    echo "baseurl_kvarray value : ${value}"
    
    # add key - value to baseurl_kvarray 
    baseurl_kvarray[${key}]=${value}
done

# ${local_repo_File} -> /tmp_file -> /etc/yum.repos.d/local.repo

touch "/tmp_file"
chmod 777 /tmp_file 
cat /dev/null > "/tmp_file" # echo "" : making blank line at the top  

echo "setting a tmp_file for local.repo ... "

cur_key=0

if [[ -f "${local_repo_file}" ]]; then  

    while IFS= read -r line; do
        
        # Section마다 다른 cur_key 적용
        if [[ $(echo ${line} | grep -P "^\[.*]$") ]]; then
            # section으로부터 baseurl_kvarray key 추출 ( 7버전 이하 : dvd / 8버전 이상 :  BaseOS, AppStream ) 
            cur_key=$(echo ${line} | cut -d "-" -f 2 | tr -d "[-]"])
        else
            true
        fi

        # baseurl Attribute Line 덮어 쓰기 : tmp_file 파일에 Redirect 
        if [[ "${line}" == *baseurl* ]]; then
            echo "${baseurl_kvarray[${cur_key}]}" >> $(find / -name "tmp_file" 2> /dev/null )
        else
            echo "${line}" >> $(find / -name "tmp_file" 2> /dev/null)
        fi

    done < "${local_repo_file}"

    # /etc/yum.repos.d/ 경로에 local.repo 생성 ( 이미 존재한다면 수정 일시 갱신 )
    touch /etc/yum.repos.d/local.repo
    chmod 777 /etc/yum.repos.d/local.repo

    # tmp_file의 내용 출력을 /etc/yum.repos.d/local.repo에 Overwrite ( > ) 
    cat $(echo $(find / -name "tmp_file")) > /etc/yum.repos.d/local.repo

else
    echo "${local_repo_file} does not exist."
fi

rm -rv /tmp_file

# 5. yum repolist 
yum repolist