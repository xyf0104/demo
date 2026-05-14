#!/bin/bash
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain}请使用 root 权限运行此脚本\n" && exit 1

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "检测操作系统失败！" >&2
    exit 1
fi
echo "当前操作系统：$release"

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${red}不支持的 CPU 架构！${plain}" && exit 1 ;;
    esac
}
echo "CPU 架构：$(arch)"

install_base() {
    case "${release}" in
    centos | almalinux | rocky | oracle)
        yum -y update && yum install -y -q wget curl tar tzdata sqlite3 socat
        ;;
    fedora)
        dnf -y update && dnf install -y -q wget curl tar tzdata sqlite socat
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata sqlite socat
        ;;
    *)
        apt-get update && apt-get install -y -q wget curl tar tzdata sqlite3 socat
        ;;
    esac
}

# ========== SSL 证书自动化 ==========
install_acme() {
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo -e "${green}acme.sh 已安装${plain}"
        return 0
    fi
    echo -e "${yellow}正在安装 acme.sh...${plain}"
    curl -sL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o /tmp/acme.tar.gz
    if [[ $? -ne 0 ]]; then
        echo -e "${red}下载 acme.sh 失败${plain}"
        return 1
    fi
    cd /tmp && tar xzf acme.tar.gz
    cd acme.sh-master && ./acme.sh --install -m ""
    cd ~ && rm -rf /tmp/acme.tar.gz /tmp/acme.sh-master
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo -e "${green}acme.sh 安装成功${plain}"
        return 0
    else
        echo -e "${red}acme.sh 安装失败${plain}"
        return 1
    fi
}

# 释放 80 端口：检测占用进程并临时停止
free_port_80() {
    PORT80_STOPPED_SERVICES=()
    PORT80_KILLED_PIDS=()

    local pid_list=$(ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP 'pid=\K\d+' | sort -u)
    if [[ -z "$pid_list" ]]; then
        # 备用方式
        pid_list=$(lsof -i :80 -t 2>/dev/null | sort -u)
    fi

    if [[ -z "$pid_list" ]]; then
        echo -e "${green}80 端口空闲${plain}"
        return 0
    fi

    echo -e "${yellow}检测到 80 端口被以下进程占用：${plain}"
    for pid in $pid_list; do
        local pname=$(ps -p "$pid" -o comm= 2>/dev/null)
        echo -e "  PID: ${pid}  进程: ${pname}"
    done

    # 尝试通过 systemd 停止常见服务
    for svc in nginx apache2 httpd caddy lighttpd s-ui; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "${yellow}正在临时停止 ${svc} 服务...${plain}"
            systemctl stop "$svc"
            PORT80_STOPPED_SERVICES+=("$svc")
        fi
    done

    # 再次检查是否还有进程占用
    sleep 1
    pid_list=$(ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP 'pid=\K\d+' | sort -u)
    if [[ -z "$pid_list" ]]; then
        pid_list=$(lsof -i :80 -t 2>/dev/null | sort -u)
    fi

    if [[ -n "$pid_list" ]]; then
        echo -e "${yellow}仍有进程占用 80 端口，正在强制结束...${plain}"
        for pid in $pid_list; do
            local pname=$(ps -p "$pid" -o comm= 2>/dev/null)
            echo -e "  强制结束 PID: ${pid} (${pname})"
            kill -9 "$pid" 2>/dev/null
            PORT80_KILLED_PIDS+=("$pid")
        done
        sleep 1
    fi

    echo -e "${green}80 端口已释放${plain}"
    return 0
}

# 恢复之前停止的服务
restore_port_80() {
    for svc in "${PORT80_STOPPED_SERVICES[@]}"; do
        if [[ "$svc" != "s-ui" ]]; then
            echo -e "${yellow}正在恢复 ${svc} 服务...${plain}"
            systemctl start "$svc" 2>/dev/null
        fi
    done
}

issue_ssl_cert() {
    local domain=$1
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    echo -e "${yellow}正在为 ${domain} 申请 SSL 证书...${plain}"

    # DNS 预检查
    echo -e "${yellow}检查域名 DNS 解析...${plain}"
    local resolved_ip=$(dig +short "$domain" A 2>/dev/null | head -1)
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(host "$domain" 2>/dev/null | grep "has address" | head -1 | awk '{print $NF}')
    fi
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
    fi

    if [[ -z "$resolved_ip" ]]; then
        echo -e "${red}域名 ${domain} 无法解析！请先在 DNS 中添加 A 记录指向本机 IP${plain}"
        echo -e "${yellow}提示：如果刚添加 DNS 记录，可能需要等待几分钟生效${plain}"
        read -p "是否仍要尝试申请？[y/n]：" force_try
        if [[ "${force_try}" != "y" && "${force_try}" != "Y" ]]; then
            return 1
        fi
    else
        echo -e "${green}域名解析正常：${domain} → ${resolved_ip}${plain}"
    fi

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # 释放 80 端口
    free_port_80

    # 检查是否已有证书记录
    local has_existing=false
    if ~/.acme.sh/acme.sh --list 2>/dev/null | grep -q "${domain}"; then
        has_existing=true
        echo -e "${yellow}检测到域名 ${domain} 已有证书记录${plain}"

        # 检查证书文件是否真的存在
        local ecc_dir="${HOME}/.acme.sh/${domain}_ecc"
        local rsa_dir="${HOME}/.acme.sh/${domain}"
        if [[ -f "${ecc_dir}/fullchain.cer" ]] || [[ -f "${rsa_dir}/fullchain.cer" ]]; then
            echo -e "${green}证书文件存在，直接安装...${plain}"
        else
            echo -e "${yellow}证书文件已丢失，使用 --force 重新申请...${plain}"
            ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 --force 2>&1
            if [[ $? -ne 0 ]]; then
                echo -e "${red}证书重新申请失败！${plain}"
                restore_port_80
                return 1
            fi
        fi
    else
        # 全新申请
        ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 2>&1
        if [[ $? -ne 0 ]]; then
            echo -e "${yellow}首次申请未成功，使用 --force 重试...${plain}"
            ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone --httpport 80 --force 2>&1
            if [[ $? -ne 0 ]]; then
                echo -e "${red}证书申请失败！请确认域名已正确解析到本机 IP${plain}"
                restore_port_80
                return 1
            fi
        fi
    fi

    # 安装证书到指定目录（先尝试 ECC，失败再尝试 RSA）
    local install_ok=false

    ~/.acme.sh/acme.sh --installcert -d "${domain}" --ecc \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" 2>&1
    if [[ $? -eq 0 ]]; then
        install_ok=true
    else
        echo -e "${yellow}ECC 方式安装失败，尝试 RSA 方式...${plain}"
        ~/.acme.sh/acme.sh --installcert -d "${domain}" \
            --key-file "${certPath}/privkey.pem" \
            --fullchain-file "${certPath}/fullchain.pem" 2>&1
        if [[ $? -eq 0 ]]; then
            install_ok=true
        fi
    fi

    if [[ "$install_ok" != true ]]; then
        echo -e "${red}证书安装到本地目录失败${plain}"
        restore_port_80
        return 1
    fi

    ~/.acme.sh/acme.sh --upgrade --auto-upgrade 2>/dev/null
    chmod 755 "${certPath}"/* 2>/dev/null

    # 恢复之前停止的服务
    restore_port_80

    echo -e "${green}✅ SSL 证书申请并安装成功！${plain}"
    echo -e "  证书：${certPath}/fullchain.pem"
    echo -e "  密钥：${certPath}/privkey.pem"
    return 0
}

# 将域名和证书路径写入 S-UI 数据库
configure_ssl_in_sui() {
    local domain=$1
    local certFile=$2
    local keyFile=$3
    local dbFile="/usr/local/s-ui/db/s-ui.db"

    if [[ ! -f "$dbFile" ]]; then
        echo -e "${yellow}数据库尚未创建，先启动一次 S-UI 以初始化...${plain}"
        systemctl start s-ui
        sleep 3
        systemctl stop s-ui
    fi

    if [[ ! -f "$dbFile" ]]; then
        echo -e "${red}数据库文件不存在，无法自动配置 SSL${plain}"
        echo -e "${yellow}请安装完成后在面板中手动配置域名和证书路径${plain}"
        return 1
    fi

    # 获取 settings 表的字段名
    local columns=$(sqlite3 "$dbFile" "PRAGMA table_info(settings);" 2>/dev/null | awk -F'|' '{print $2}')
    
    # 尝试不同的可能字段名来更新域名
    for col in domain Domain; do
        if echo "$columns" | grep -qw "$col"; then
            sqlite3 "$dbFile" "UPDATE settings SET ${col}='${domain}';" 2>/dev/null
            echo -e "${green}已设置域名：${domain}${plain}"
            break
        fi
    done

    # 尝试不同的可能字段名来更新证书路径
    for col in cert_file certFile ssl_cert_path sslCertFile cert_path; do
        if echo "$columns" | grep -qw "$col"; then
            sqlite3 "$dbFile" "UPDATE settings SET ${col}='${certFile}';" 2>/dev/null
            echo -e "${green}已设置证书路径：${certFile}${plain}"
            break
        fi
    done

    # 尝试不同的可能字段名来更新密钥路径
    for col in key_file keyFile ssl_key_path sslKeyFile key_path; do
        if echo "$columns" | grep -qw "$col"; then
            sqlite3 "$dbFile" "UPDATE settings SET ${col}='${keyFile}';" 2>/dev/null
            echo -e "${green}已设置密钥路径：${keyFile}${plain}"
            break
        fi
    done

    return 0
}

# ========== 安装后交互配置 ==========
config_after_install() {
    echo -e "${yellow}正在迁移数据...${plain}"
    /usr/local/s-ui/sui migrate

    echo -e "${yellow}安装/更新完成！为安全起见，建议修改面板设置${plain}"
    read -p "是否修改面板设置？[y/n]：" config_confirm
    if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        echo -e "请输入${yellow}面板端口${plain}（留空使用默认值）："
        read config_port
        echo -e "请输入${yellow}面板路径${plain}（留空使用默认值）："
        read config_path
        echo -e "请输入${yellow}订阅端口${plain}（留空使用默认值）："
        read config_subPort
        echo -e "请输入${yellow}订阅路径${plain}（留空使用默认值）："
        read config_subPath

        echo -e "${yellow}正在初始化...${plain}"
        params=""
        [ -z "$config_port" ] || params="$params -port $config_port"
        [ -z "$config_path" ] || params="$params -path $config_path"
        [ -z "$config_subPort" ] || params="$params -subPort $config_subPort"
        [ -z "$config_subPath" ] || params="$params -subPath $config_subPath"
        /usr/local/s-ui/sui setting ${params}

        read -p "是否修改管理员账号密码？[y/n]：" admin_confirm
        if [[ "${admin_confirm}" == "y" || "${admin_confirm}" == "Y" ]]; then
            read -p "请设置用户名：" config_account
            read -p "请设置密码：" config_password
            /usr/local/s-ui/sui admin -username ${config_account} -password ${config_password}
        else
            echo -e "${yellow}当前管理员凭据：${plain}"
            /usr/local/s-ui/sui admin -show
        fi
    else
        echo -e "${red}已跳过面板设置${plain}"
        if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
            local usernameTemp=$(head -c 6 /dev/urandom | base64)
            local passwordTemp=$(head -c 6 /dev/urandom | base64)
            echo -e "首次安装，已自动生成随机登录信息："
            echo -e "###############################################"
            echo -e "${green}用户名：${usernameTemp}${plain}"
            echo -e "${green}密  码：${passwordTemp}${plain}"
            echo -e "###############################################"
            echo -e "${red}忘记登录信息请输入 ${green}s-ui${red} 进入管理菜单${plain}"
            /usr/local/s-ui/sui admin -username ${usernameTemp} -password ${passwordTemp}
        else
            echo -e "${yellow}升级安装，保留原有设置。忘记登录信息请输入 ${green}s-ui${yellow} 进入管理菜单${plain}"
        fi
    fi
}

# ========== 域名 & SSL 交互配置 ==========
config_domain_ssl() {
    echo ""
    echo -e "————————————————————————————————————"
    echo -e "${green}域名 & SSL 证书配置${plain}"
    echo -e "————————————————————————————————————"
    read -p "是否为面板配置域名和 SSL 证书？[y/n]：" ssl_confirm

    if [[ "${ssl_confirm}" != "y" && "${ssl_confirm}" != "Y" ]]; then
        echo -e "${yellow}已跳过域名配置，使用 IP + 端口访问${plain}"
        SSL_CONFIGURED=false
        return
    fi

    read -p "请输入已解析到本机的域名（如 panel.example.com）：" input_domain
    input_domain=$(echo "$input_domain" | tr -d '[:space:]')

    if [[ -z "$input_domain" ]]; then
        echo -e "${red}域名不能为空，已跳过${plain}"
        SSL_CONFIGURED=false
        return
    fi

    # 安装 acme.sh
    install_acme
    if [[ $? -ne 0 ]]; then
        echo -e "${red}acme.sh 安装失败，跳过 SSL 配置${plain}"
        SSL_CONFIGURED=false
        return
    fi

    # 临时停止 S-UI 以释放端口
    systemctl stop s-ui 2>/dev/null

    # 申请证书
    issue_ssl_cert "$input_domain"
    if [[ $? -ne 0 ]]; then
        echo -e "${red}证书申请失败，跳过 SSL 配置${plain}"
        SSL_CONFIGURED=false
        systemctl start s-ui 2>/dev/null
        return
    fi

    # 写入 S-UI 配置
    local certFile="/root/cert/${input_domain}/fullchain.pem"
    local keyFile="/root/cert/${input_domain}/privkey.pem"
    configure_ssl_in_sui "$input_domain" "$certFile" "$keyFile"

    SSL_CONFIGURED=true
    SSL_DOMAIN="$input_domain"
    SSL_CERT="$certFile"
    SSL_KEY="$keyFile"
}

# ========== 服务准备 ==========
prepare_services() {
    if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
        echo -e "${yellow}正在停止 sing-box 服务...${plain}"
        systemctl stop sing-box
        rm -f /usr/local/s-ui/bin/sing-box /usr/local/s-ui/bin/runSingbox.sh /usr/local/s-ui/bin/signal
    fi
    if [[ -e "/usr/local/s-ui/bin" ]]; then
        echo -e "###############################################################"
        echo -e "${green}/usr/local/s-ui/bin${red} 目录仍然存在！"
        echo -e "请迁移完成后手动删除${plain}"
        echo -e "###############################################################"
    fi
    systemctl daemon-reload
}

# ========== 主安装函数 ==========
install_s-ui() {
    cd /tmp/

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/bulianglin/demo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}获取 S-UI 版本失败，可能是 GitHub API 限制${plain}"
            exit 1
        fi
        echo -e "最新版本：${green}${last_version}${plain}，开始下载..."
        wget -N --no-check-certificate -O /tmp/s-ui-linux-$(arch).tar.gz \
            https://github.com/bulianglin/demo/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 S-UI 失败，请确保服务器能访问 GitHub${plain}"
            exit 1
        fi
    else
        last_version=$1
        echo -e "开始安装 S-UI ${green}v$1${plain}"
        wget -N --no-check-certificate -O /tmp/s-ui-linux-$(arch).tar.gz \
            "https://github.com/bulianglin/demo/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 S-UI v$1 失败，请确认版本是否存在${plain}"
            exit 1
        fi
    fi

    if [[ -e /usr/local/s-ui/ ]]; then
        systemctl stop s-ui
    fi

    tar zxvf s-ui-linux-$(arch).tar.gz
    rm s-ui-linux-$(arch).tar.gz -f

    chmod +x s-ui/sui s-ui/s-ui.sh

    # 下载汉化版管理脚本覆盖原版
    echo -e "${yellow}正在下载汉化版管理脚本...${plain}"
    curl -sL https://raw.githubusercontent.com/xyf0104/demo/main/s-ui.sh -o s-ui/s-ui.sh
    chmod +x s-ui/s-ui.sh

    cp s-ui/s-ui.sh /usr/bin/s-ui
    cp -rf s-ui /usr/local/
    cp -f s-ui/*.service /etc/systemd/system/
    rm -rf s-ui

    config_after_install
    prepare_services

    systemctl enable s-ui --now

    # 域名 & SSL 配置（安装完成后）
    config_domain_ssl

    # 如果配置了 SSL，重启服务使配置生效
    if [[ "$SSL_CONFIGURED" == true ]]; then
        echo -e "${yellow}正在重启 S-UI 以加载 SSL 配置...${plain}"
        systemctl restart s-ui
        sleep 2
    fi

    echo ""
    echo -e "————————————————————————————————————"
    echo -e "${green}S-UI v${last_version} 安装完成！${plain}"
    echo -e "————————————————————————————————————"

    if [[ "$SSL_CONFIGURED" == true ]]; then
        # 获取配置的端口和路径
        local panel_port=$(grep -oP 'port.*?(\d+)' /usr/local/s-ui/db/s-ui.db 2>/dev/null || echo "")
        # 从 sui uri 获取
        local uri_info=$(/usr/local/s-ui/sui uri 2>/dev/null)
        echo -e "${green}面板访问地址：${plain}"
        echo -e "${green}  https://${SSL_DOMAIN}${plain}"
        echo -e ""
        echo -e "${yellow}如果端口非 443，请在域名后加上端口号${plain}"
        echo -e "${yellow}证书路径：${SSL_CERT}${plain}"
        echo -e "${yellow}密钥路径：${SSL_KEY}${plain}"
    else
        echo -e "${green}面板访问地址：${plain}"
        /usr/local/s-ui/sui uri
    fi

    echo -e "${plain}"
    echo ""
    s-ui help
}

echo -e "${green}开始执行 S-UI 安装...${plain}"
install_base
install_s-ui $1
