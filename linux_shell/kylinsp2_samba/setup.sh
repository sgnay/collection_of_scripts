#!/bin/bash

printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "安装 samba 包"
dnf localinstall -y pkg/*.rpm

printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "输入共享名（如：share1）"
read -p ": " sharename
printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "输入共享路径（如：/data/共享目录）"
read -p ": " sharepath
printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "输入共享用户（如：_user01）"
read -p ": " username
printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "输入共享用户密码"
read -p ": " userpass
printf "$(tput sgr0)$(tput setaf 1)%s$(tput sgr0)\n" "你的输入:"
printf "\t$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "共享名: ${sharename},"
printf "\t$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "共享路径: ${sharepath},"
printf "\t$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "共享用户: ${username},"
printf "\t$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "用户密码：${userpass}."

read -n1 -p "输入 y 继续，输入 n 退出:" input_confirm
until [[ ${input_confirm} == "y" || ${input_confirm} == "n" ]]
do
    printf "\n$(tput sgr0)$(tput setaf 1)%s$(tput sgr0)\n" "输入错误!"
    read -n1 -p "输入 y 继续，输入 n 退出:" input_confirm
done
if [[ ${input_confirm} == "n" ]]; then
    printf "\n$(tput sgr0)$(tput setaf 1)%s$(tput sgr0)\n" "用户退出"
    exit 1
fi

printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "生成 samba 配置"
cp /etc/samba/smb.conf /etc/samba/smb.conf."$(date +%s)${RANDOM}"
sed 's/sharename/'"${sharename}"'/' smb.conf | sed 's#/path/to/share#'"${sharepath}"'#' | sed 's#user01#'"${username}"'#' > /etc/samba/smb.conf
printf "$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "添加 samba 用户"
userdel ${username}
useradd -M -s /usr/sbin/nologin $username
[[ $? -ne 0 ]] && {
    printf "\n$(tput sgr0)$(tput setaf 1)%s$(tput sgr0)\n" "用户添加失败"
    exit 2
}
smbpasswd -a -s ${username} << EOF
${userpass}
${userpass}
EOF

systemctl enable --now smb
testparm -s

\cp rsyslog_smb.conf /etc/rsyslog.d/
systemctl restart smb rsyslog
