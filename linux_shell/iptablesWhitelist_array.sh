#!/bin/bash
#
#  Name: iptablesWhitelist.sh
#  Author: yangs
#  Version: 0.2.0
#  Describe: 本脚本为白名单机制，允许内部 IP 白名单访问本机所有端口，允许管理和业务能访问指定的端口，其它任何连接都予以阻止。
#
#  Variable: 添加连续 ip 格式形式如 10.124.241.100-10.124.241.105。
#            添加整个 IP 网段，使用形式 subnet/cidr，如 10.124.242.0/24.
#            添加单个 IP ，使用格式 10.124.241.11 或 10.124.241.11/32。
#            添加连续端口格式形式如 8080:8085。
#            不同 ip 之间，不同端口之间以空格分隔开，整体以英文小括号包围。
#  Usage: 修改脚本头部变量后，使用 bash 执行即可。

# 是否需要开启调试 true 或 false
# 调试完成后改成 false
debug=false
custom_chain_name="sgCustomChains"

# 管理 IP 地址白名单（任意 IP 使用 0.0.0.0/0 形式），允许以下 IP 地址访问指定的 "管理端口"，IP 列表留空不执行本项。
# 如 web 页面 80, 443 端口，后台 ssh 服务 22 端口
mgm_ip_addresses=(172.16.25.0/24 192.168.61.0/24 192.168.1.152 192.168.1.160 192.168.1.200-192.168.1.205)
mgm_tcp_ports=(80 22 6080 5900:5910 9535 9527 1 2 3 4 5 6 7 8 9 10) # tcp协议端口
mgm_udp_ports=() # udp协议端口

# 业务 IP 地址白名单（任意 IP 使用 0.0.0.0/0 形式），允许以下 IP 地址访问指定的 "业务端口"，IP 列表留空不执行本项。
# 如:samba一般需tcp端口139,445和udp端口137,138; NFSv4服务需要2049 tcp/udp端口，如果使用lockd和quotad则还需要额外端口,NFSv3和NFSv2需要tcp、udp端口111支持portmapper服务，或在服务器端使用命令 rpcinfo -p 127.1 查询; ftp服务需要tcp的端口21,35000:50000，ftp动态端口范围需要修改ftp服务配置进行限制。
bus_ip_addresses=(192.168.61.0/24 172.16.22.70-172.16.22.85 172.16.22.41)
bus_tcp_ports=(21 111 445 2059 35000:50000)
bus_udp_ports=(137 138 111)

# 内部 IP 白名单（包括vip），切忌随意添加 IP，它们会被无条件信任
whitelist_ip_addresses=(10.124.241.11 172.16.25.0/24 10.124.241.66-10.124.241.74 192.168.1.0/24)

# 选择如何处理 ICMP ping行为（默认只处理三种行为，按需求选择）：
# 1. 允许所有 ip ping 本机。
# 2. 允许内部 ip 和白名单 ping 本机。
icmp_action=2

# ---------------------------------------------------------------------------------------------------------
# -------------------------------------以下内容无需修改，只需配置以上变量---------------------------------------
# ---------------------------------------------------------------------------------------------------------
fPrint() {
    case $1 in
        info )
            printf "\n$(tput sgr0)$(tput setaf 2)%s$(tput sgr0)\n" "${2}"
            ;;
        warn )
            printf "\n$(tput sgr0)$(tput setaf 1)$(tput setab 7)$(tput blink)%s$(tput sgr0)\n" "${2}"
            ;;
        iptables )
            fPrint warn "${2}"
            fPrint info ">>> 打印 INPUT 规则中自定义规则链 ${custom_chain_name} 位置 <<<"
            iptables -nvL INPUT --line-number | grep -C3 "${custom_chain_name}" || fPrint info ">>> 自定义规则链 ${custom_chain_name} 不在 INPUT 中 <<<"
            fPrint info ">>> 打印自定义规则链 ${custom_chain_name} 内容 <<<"
            iptables -nvL "${custom_chain_name}" --line-number 2>/dev/null || fPrint info ">>> 自定义规则链 ${custom_chain_name} 不存在 <<<"
            ;;
        * )
            fPrint info "... 使用方法：fPrint info|warn|iptables \"要直接打印的内容\""
            ;;
    esac
}

fInit() {
    # initialization
    fPrint iptables "... 初始化之前,打印自定义的相关规则"
    # remove Custom Chains entry from INPUT
    iptables -P INPUT ACCEPT
    entry_seq="$(iptables -nvL INPUT --line-number | grep "${custom_chain_name}" | awk '{print $1}' | sort -nr)"
    if [ -n "${entry_seq}" ] ; then
            for i in ${entry_seq} ; do
                    iptables -D INPUT "$i"
            done
    fi
    # clear rules
    iptables -t filter -F "${custom_chain_name}" 2>/dev/null || iptables -t filter -N "${custom_chain_name}"
}

fCheckIp() { # 传入数组引用形式 array[@]
   local IFS=" -"
   for ip in ${!1} ;do
       if ! ipcalc -c "${ip}" -s ; then
       fPrint warn "... ip 地址列表 ${1%???} 中 ${ip:=连续横线} 格式错误！"
       exit 1
       fi
   done
}

fCheckPort() { # usage: fCheckPort array mgm_tcp_ports[@]
    case $1 in
    array ) # 传入数组的引用形式 array[@] ，数组内容为端口
        out_str=${2%???}
        local IFS=" :"
        fCheckPort any "${2}" || {
        return 2
        }
        ;;
    str ) # 传入变量名，变量内容为以逗号分隔的端口列表
        out_str=${2}
        local IFS=",:"
        fCheckPort any "${2}" || {
        return 2
        }
        ;;
    * )
        for port in ${!2} ; do
            [[ "$port" =~ ^[1-9][0-9]*$ && "${port}" -lt 65536 ]] || {
                fPrint warn "... 端口列表 ${out_str} 中 ${port:=连续冒号} 存在错误！"
                return 2
            }
        done
        ;;
    esac
}

fCheckVar() { # 检查输入的变量合法性
    if [ -z "${whitelist_ip_addresses[0]}" ] ;then
        fPrint warn "... 信任白名单不能为空，停止脚本执行!"
        exit 1
    else
        for ips in mgm_ip_addresses bus_ip_addresses whitelist_ip_addresses ;do
            fCheckIp "${ips}"
        done
        for port_array in mgm_tcp_ports mgm_udp_ports bus_tcp_ports bus_udp_ports ; do
            fCheckPort array "${port_array}[@]" || exit 2
        done
    fi
}

fSplitPorts() { # usage: fSplitPorts mgm_tcp_ports[@]
    # multiport 每条规则最多仅支持 15 个端口参数，端口范围 start:end 消耗 2 个参数位置。此函数将传入的端口数组字面量形式 array[@]，将数组分割处理后重新定义数组 new_port_groups
    declare -a port_groups=() # 局部变量，一级数组用于存放二级数组名
    declare -i count=0 # 二级数组成员计数
    declare -i index=0 # 一级数组编号
    declare -i sub_index=0 # 二级数组编号
    for port in ${!1} ;do
        if (( count == 0 )) ; then # 二级数组成员数为 0 时创建新的二级数组
            port_groups[index]=port_group_${index}
        fi
        declare "port_group_${index}[$sub_index]"="$port" # 为二级数组添加一个成员，并将编号增加 1
        (( ++sub_index ))
        if printf "%s" "${port}" | grep ":" &>/dev/null ; then # 当成员是 "端口范围" 时占用两个成员计数
            ((count=count+2))
        else
            ((++count))
        fi
        if (( count > 13 )) ;then # 成员计数最大为 15，按最坏预测下一轮为 "端口范围" ，当前计数加 2 不可超过 15
            ((++index))
            count=0
            sub_index=0
        fi
    done
    # new_port_groups=()
    # while IFS='' read -r line; do new_port_groups+=("$line"); done < <(
    mapfile -t new_port_groups < <( # 将分好的端口组按逗号分隔拼接成新的数组，每个成员可以被 multiport 直接使用
    for port_group in "${port_groups[@]}" ; do 
        comb_port_group="${port_group}[@]"
        echo "${!comb_port_group}" | tr " " ","
    done
    )
    for port_list in "${new_port_groups[@]}" ; do # 校验新端口组的合法性
        fCheckPort str port_list || {
            printf "\033[2A"
            fPrint warn "... 内部错误：端口列表 ${1%???} 分割操作失败!"
            fPrint info "... 错误内容：$port_list"
            exit 1
        }
    done
}

fApp() {
    case $1 in
        mgm | bus )
            comb_ip_addresses="${1}_ip_addresses[*]"
            ip_addresses="${!comb_ip_addresses}"
            fSplitPorts "${1}_tcp_ports[@]"
            tcp_ports="${new_port_groups[*]}"
            fSplitPorts "${1}_udp_ports[@]"
            udp_ports="${new_port_groups[*]}"
            fApp app
            ;;
        app )
            for ip in ${ip_addresses} ;do
                if echo "${ip}" | grep "-" &>/dev/null ;then
                    fApp range tcp_ports
                    fApp range udp_ports
                else
                    fApp indep tcp_ports
                    fApp indep udp_ports
                fi
            done
            ;;
        * )
            if [ "${1}" == range ] ; then
                for ports in ${!2} ;do
                    iptables -I "${custom_chain_name}" -m iprange --src-range "${ip}" -p "${2%%_*}" -m multiport --dport "${ports}" -j ACCEPT
                done
            else
                for ports in ${!2} ;do
                    iptables -I "${custom_chain_name}" -s "${ip}" -p "${2%%_*}" -m multiport --dport "${ports}" -j ACCEPT
                done
            fi
            ;;
    esac
}

fTrust() {
    # 允许这些 IP 地址访问本地的任意协议和端口
    local IFS=","
    for k in "${whitelist_ip_addresses[@]}" ;do
        if echo "${k}" | grep "-" &>/dev/null ;then
            iptables -I "${custom_chain_name}" -m iprange --src-range "${k}" -p all -j ACCEPT -m comment --comment "信任这些IP"
        else
            iptables -I "${custom_chain_name}" -s "${k}" -p all -j ACCEPT -m comment --comment "信任这个IP或段"
        fi
    done
}

fSetIcmp() {
# 1. "allow_all_icmp" 允许所有 ip ping 本机。
# 2. "allow_whitelist_icmp" 允许内部 ip 和白名单 ping 本机
    case $1 in
        1|allow_all_icmp )
            iptables -I "${custom_chain_name}" -p icmp --icmp-type any -j ACCEPT -m comment --comment "允许所有 ip ping 本机 icmp"
            ;;
        ban_icmp )
            iptables -I "${custom_chain_name}" -p icmp --icmp-type any -j DROP -m comment --comment "禁止 ping 本机 icmp"
            ;;
        2|allow_whitelist_icmp )
            iptables -A "${custom_chain_name}" -p icmp --icmp-type any -j DROP -m comment --comment "仅允许内部 ip 和白名单 ping 本机 icmp"
            ;;
        * )
            fPrint warn "... icmp 规则处理错误，请检查脚本 icmp_action 的值!"
            ;;
    esac
}

fAddToInput() {
    # 应用自定义规则的方法，默认插入到第一条
    # iptables -I INPUT 1 -j "${custom_chain_name}" -m comment --comment "截获所有 INPUT 包进入自定义规则链 ${custom_chain_name}"
    # 插入到 neutron 或 KUBE-ROUTER-SERVICES, KUBE-FIREWALL  规则的后面
    linenumber=$(iptables -nvL INPUT --line-number | grep -E 'KUBE|neutron-openvswi-INPUT' | sort -nr -k1 | awk 'NR==1{print $1}')
    if [ -z "${linenumber}" ] ; then
        # 没找到关键字，插入到 INPUT 第一行
        iptables -I INPUT 1 -j "${custom_chain_name}" -m comment --comment "截获所有 INPUT 包进入自定义规则链 ${custom_chain_name}"
    else
        iptables -I INPUT $((linenumber+1)) -j "${custom_chain_name}" -m comment --comment "截获所有 INPUT 包进入自定义规则链 ${custom_chain_name}"
    fi

}

fEnd() {
    # Final stage, deal with icmp, trust loopback and complete the custom chain
    fSetIcmp ${icmp_action}
    iptables -I "${custom_chain_name}" -i lo -j ACCEPT -m comment --comment "信任 lo 回环"
    iptables -A "${custom_chain_name}" -p all -j DROP -m comment --comment "丢弃所有数据包，本条规则以下规则全部无效"
    fAddToInput
    [[ $(echo $debug |tr '[:upper:]' '[:lower:]') == "true" ]] && {
        fPrint info "开启调试，规则已应用，但稍后将会被删除！"
        iptables -A "${custom_chain_name}" -m state --state RELATED,ESTABLISHED -j ACCEPT -m comment --comment "不中断已经建立的连接，放行相关流量"
        (sleep 30 && fInit &>/dev/null &)
    }
    fPrint iptables "... 全部处理结束后,打印自定义的相关规则"
}

fMain() {
    fCheckVar
    fInit
    fApp mgm
    fApp bus
    fTrust
    fEnd
}
fMain
