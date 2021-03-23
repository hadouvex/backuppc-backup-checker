#!/bin/bash

source .env

# Dir strings mustn't contain '/' at the end

#TG_BOT_TOKEN <- .env
#TG_CHAT_ID <- .env
TG_BOT_API_BASE_LINK='https://api.telegram.org/bot'

#HOSTS_SRC_REMOTE <- .env [true, false]

#HOSTS_SRC_FILE <- .env
#HOSTS_SRC_HOST <- .env

#BACKUPPC_HOST_HOSTNAME <- .env

#BACKUPS_SRC_HOST <- .env
#BACKUPS_SRC_DIR <- .env

#SSH_USER <- .env

HOSTS_FILE_UNEDITED='all_hosts.txt'
HOSTS_FILE_TRIMMED='all_hosts_trimmed.txt'
HOSTS_FILE_BACKUPS_REQUIRED='required_hosts.txt'
HOSTS_FILE_BACKUPS_EXISTENT='hosts_with_backups.txt'

SED_REGEX_FILE='sed_regex.txt'

HOSTS_EXCEPTIONS_FILE='hosts_exceptions'

hosts_with_backups_total_count=0

hosts_with_required_backups=()
hosts_with_unrequired_backups=()
hosts_without_required_backups=()

sed_regex_string=""

declare -A backups_per_host_required
declare -A latest_backup_date_for_host_required
declare -A oldest_backup_date_for_host_required

hosts_exceptions=()

if [[ -e $HOSTS_EXCEPTIONS_FILE && -s $HOSTS_EXCEPTIONS_FILE ]]; then
    while read line; do
        hosts_exceptions+=($line)
    done < $HOSTS_EXCEPTIONS_FILE
fi

get_hosts_from_remote_host_and_write_to_file () {
    scp -q $SSH_USER@$HOSTS_SRC_HOST:$HOSTS_SRC_FILE $HOSTS_FILE_UNEDITED
}

get_hosts_from_local_host_and_write_to_file () {
    cp $HOSTS_SRC_FILE $HOSTS_FILE_UNEDITED
}

trim_hosts_file () {
    if [[ -e $HOSTS_FILE_TRIMMED ]]; then rm $HOSTS_FILE_TRIMMED; fi
    while read line; do
        echo $line | sed '/^$/d ; /^#/d ; /ip6/d ; /localhost/d ; /office/d ; /broadcasthost/d' | head -n1 | cut -d " " -f2 >> $HOSTS_FILE_TRIMMED
    done < $HOSTS_FILE_UNEDITED
}

generate_sed_string_from_file () {
    while read line; do
        sed_regex_string+="/${line}/d ; "
    done < $SED_REGEX_FILE
}

get_required_hosts_from_trimmed_hosts_file () {
    if [[ -e $HOSTS_FILE_BACKUPS_REQUIRED ]]; then rm $HOSTS_FILE_BACKUPS_REQUIRED; fi

    cp $HOSTS_FILE_TRIMMED $HOSTS_FILE_BACKUPS_REQUIRED

    if [[ -s $SED_REGEX_FILE ]]; then
        generate_sed_string_from_file
    else
        echo "Sed regex file doesn't exist or it is empty! No filter will be applied..."
    fi

    while read line; do
        sed -E -i "$sed_regex_string" $HOSTS_FILE_BACKUPS_REQUIRED
    done < $HOSTS_FILE_TRIMMED
    
    for host in ${hosts_exceptions[@]}; do
        echo $host >> $HOSTS_FILE_BACKUPS_REQUIRED
    done
}

get_existent_backups_from_remote () {
    ssh $SSH_USER@$BACKUPS_SRC_HOST sudo ls $BACKUPS_SRC_DIR | cat > $HOSTS_FILE_BACKUPS_EXISTENT
}

get_existent_backups_from_localhost () {
    sudo ls $BACKUPS_SRC_DIR | cat > $HOSTS_FILE_BACKUPS_EXISTENT
}

match_required_backups_with_existent () {
    while read r_line; do
        if [[ $(cat $HOSTS_FILE_BACKUPS_EXISTENT | grep $r_line) == $r_line ]]; then
            hosts_with_required_backups+=($r_line)
        else
            hosts_without_required_backups+=($r_line)
        fi
    done < $HOSTS_FILE_BACKUPS_REQUIRED
}

match_existent_backups_with_required () {
    while read e_line; do
        if [[ $(cat $HOSTS_FILE_BACKUPS_REQUIRED | grep $e_line) != $e_line ]]; then
            hosts_with_unrequired_backups+=($e_line)
        fi
    done < $HOSTS_FILE_BACKUPS_EXISTENT
}

count_backups_total () {
    hosts_with_backups_total_count=$(cat $HOSTS_FILE_BACKUPS_EXISTENT | wc -l)
}

get_backups_per_host_required () {
    counter=0
    hosts_count=${#hosts_with_required_backups[@]}
    echo -e "\nCounting backups for hosts. This may take some time if executing remotely...\n"
    if [[ $(hostname) =~ "${BACKUPS_SRC_HOST}" ]]; then
        for host in ${hosts_with_required_backups[@]}; do
            backups_per_host_required[$host]=$(sudo ls $BACKUPS_SRC_DIR/$host | grep -E '^[0-9].*[0-9]$' | wc -l)
            (( counter++ ))
            echo "$counter/$hosts_count"
        done
    else
        for host in ${hosts_with_required_backups[@]}; do
            backups_per_host_required[$host]=$(ssh $SSH_USER@$BACKUPS_SRC_HOST sudo ls $BACKUPS_SRC_DIR/$host | grep -E '^[0-9].*[0-9]$' | wc -l)
            (( counter++ ))
            echo "$counter/$hosts_count"
        done
    fi

    echo -e "\n...Done."
}

get_latest_and_oldest_backup_date_for_hosts_required_from_remote_host () {
    for host in ${hosts_with_required_backups[@]}; do
        latest_date=''
        oldest_date=''
        
        if [[ $(hostname) =~ "${BACKUPS_SRC_HOST}" ]]; then
            tmp=$(sudo ls -lah $BACKUPS_SRC_DIR/$host)
        else
            tmp=$(ssh $SSH_USER@$BACKUPS_SRC_HOST sudo ls -lah $BACKUPS_SRC_DIR/$host)
        fi

        tmp=$(cat <<< $tmp | awk '{print $6, $7, $8, $9;}' | grep -E "[0-9]+$" | sed '/LOG/d ; /Info/d')

        while read line; do
            month=$(echo $line | awk '{print $1}')
            day=$(echo $line | awk '{print $2}')
            time_year=$(echo $line | awk '{print $3}')
            if [[ $time_year =~ ':' ]]; then
                if [[ $(date +%m%d) < $(date -d "${month}${day}" +%m%d) ]]; then
                    year=$(($(date +%Y) - 1))
                else
                    year=$(date +%Y)
                fi
            else
                year=$time_year
            fi

            date_var=$(date -d "${month}-${day}-${year}" +"%Y-%m-%d")

            if [[ -z $latest_date ]]; then
                latest_date=$date_var
            fi

            if [[ -z $oldest_date ]]; then
                oldest_date=$date_var
            fi

            if [[ $date_var > $latest_date ]]; then
                latest_date=$date_var
            fi

            if [[ $date_var < $oldest_date ]]; then
                oldest_date=$date_var
            fi

        done <<< $(cat <<< $tmp)

        latest_backup_date_for_host_required[$host]=$latest_date
        oldest_backup_date_for_host_required[$host]=$oldest_date
    done
}

print_summary () {
    bold=$(tput bold)
    green=$(tput setaf 2)
    orange=$(tput setaf 3)
    red=$(tput setaf 1)
    default=$(tput sgr0)
    s_underline=$(tput smul)
    r_underline=$(tput rmul);

    echo -e "${bold}\n----------------------------------------SUMMARY:\n${default}"
    echo -e "${bold}$hosts_with_backups_total_count${default} hosts with backups were found in ${bold}total${default}.\n"
    echo -e "${green}${bold}${#hosts_with_required_backups[@]}${default}${green} hosts have ${bold}required${default}${green} backups.\n"
    if [[ "$@" =~ 'h' ]]; then
        for host in ${hosts_with_required_backups[@]}; do
            if [[ "$@" =~ 'c' && "$@" =~ 'd' ]]; then
                if [[ ${backups_per_host_required[$host]} != 0 ]]; then
                    echo "$host : ${bold}${backups_per_host_required[$host]}${default}${green} [${latest_backup_date_for_host_required[$host]}/${oldest_backup_date_for_host_required[$host]}]"
                else
                    echo "$host : ${red}${bold}there is a directory for this host, but no backups!${default}${green}"
                fi
            elif [[ "$@" =~ 'c' ]]; then
                if [[ ${backups_per_host_required[$host]} != 0 ]]; then
                    echo "$host : ${backups_per_host_required[$host]}"
                else
                    echo "$host : ${red}${bold}there is a directory for this host, but no backups!${default}${green}"
                fi
            elif [[ "$@" =~ 'd' ]]; then
                echo "$host : latest: ${latest_backup_date_for_host_required[$host]} oldest: ${oldest_backup_date_for_host_required[$host]}"
            else
                echo $host
            fi
        done
        echo
    fi
    echo -e "${orange}${bold}${#hosts_with_unrequired_backups[@]}${default}${orange} hosts have ${bold}unrequired${default}${orange} backups.\n "
    if [[ "$@" =~ 'h' ]]; then
        for host in ${hosts_with_unrequired_backups[@]}; do
            echo $host
        done
        echo
    fi
    echo -e "${red}${bold}${#hosts_without_required_backups[@]}${default}${red} hosts ${bold}${s_underline}miss${r_underline} required${default}${red} backups!\n"
    if [[ "$@" =~ 'h' ]]; then
        for host in ${hosts_without_required_backups[@]}; do
            echo $host
        done
        echo
    fi
    tput sgr0
}

run_tg_mode () {
    nl='%0A'
    sp='%20'

    if [[ $(hostname) =~ "${BACKUPS_SRC_HOST}" ]]; then
        get_hosts_from_local_host_and_write_to_file
    else
        get_hosts_from_remote_host_and_write_to_file
    fi
    trim_hosts_file
    get_required_hosts_from_trimmed_hosts_file
    if [[ $(hostname) =~ "${BACKUPS_SRC_HOST}" ]]; then
        get_existent_backups_from_localhost
    else
        get_existent_backups_from_remote
    fi
    match_required_backups_with_existent
    count_backups_total
    match_existent_backups_with_required

    message=""

    message+="Hosts${sp}with${sp}backups${sp}total:${sp}${hosts_with_backups_total_count}${nl}${nl}"

    message+="Hosts${sp}with${sp}required${sp}backups:${sp}${#hosts_with_required_backups[@]}${nl}${nl}"

    if [[ "$@" =~ 'h' ]]; then
        for i in ${hosts_with_required_backups[@]}; do
            message+=$i
            message+="${nl}"
        done
        message+="${nl}"
    fi

    message+="Hosts${sp}with${sp}unrequired${sp}backups:${sp}${#hosts_with_unrequired_backups[@]}${nl}${nl}"

    if [[ "$@" =~ 'h' ]]; then
        for i in ${hosts_with_unrequired_backups[@]}; do
            message+=$i
            message+="${nl}"
        done
        message+="${nl}"
    fi

    message+="Hosts${sp}without${sp}required${sp}backups:${sp}${#hosts_without_required_backups[@]}${nl}${nl}"

    if [[ "$@" =~ 'h' ]]; then
        for i in ${hosts_without_required_backups[@]}; do
            message+=$i
            message+="${nl}"
        done
        message+="${nl}"
    fi

    # echo $message > output.txt

    curl -s "${TG_BOT_API_BASE_LINK}${TG_BOT_TOKEN}/sendMessage?chat_id=${TG_CHAT_ID}&text=${message}" > /dev/null
}

run_normal_mode () {
    if [[ $(hostname) =~ "${BACKUPS_SRC_HOST}" ]]; then
        get_hosts_from_local_host_and_write_to_file
    else
        get_hosts_from_remote_host_and_write_to_file
    fi
    trim_hosts_file
    get_required_hosts_from_trimmed_hosts_file
    if [[ $(hostname) =~ "${BACKUPS_SRC_HOST}" ]]; then
        get_existent_backups_from_localhost
    else
        get_existent_backups_from_remote
    fi
    match_required_backups_with_existent
    count_backups_total
    match_existent_backups_with_required
    if [[ "$@" =~ 'c' ]]; then
        get_backups_per_host_required
    fi
    if [[ "$@" =~ 'd' ]]; then
        get_latest_and_oldest_backup_date_for_hosts_required_from_remote_host
    fi
    print_summary $@

    
}

main () {
    if [[ "$@" =~ 't' ]]; then
        run_tg_mode $@
    else
        run_normal_mode $@
    fi
}

main $@
