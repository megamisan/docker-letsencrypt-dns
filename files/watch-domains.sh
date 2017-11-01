#!/bin/sh

autorestart_pattern="autorestart-containers="

staging_cmd=""
if [ "$LETSENCRYPT_STAGING" = true ]; then
    staging_cmd="--staging"
fi

current_hash=
while true; do
    # Calculate the new domains.conf file hash
    new_hash=`md5sum /etc/letsencrypt/domains.conf | awk '{ print $1 }'`
    if [ "$current_hash" != "$new_hash" ]; then
        # Clean all autorestart containers instances
        rm -f /etc/supervisord.d/*_autorestart-containers

        echo "#### Registering Let's Encrypt account if needed ####"
        certbot register -n --agree-tos -m $LETSENCRYPT_USER_MAIL $staging_cmd

        echo "#### Creating missing certificates if needed (~1min for each) ####"
        while read entry; do
            domains_cmd=""
            main_domain=""
            containers=""

            for domain in $entry; do
                if [ "${domain#*$autorestart_pattern}" != "$domain" ]; then
                    containers=${domain/autorestart-containers=/}
                elif [ -z $main_domain ]; then
                    main_domain=$domain
                    domains_cmd="$domains_cmd -d $domain"
                else
                    domains_cmd="$domains_cmd -d $domain"
                fi
            done

            echo ">>> Creating a certificate for domain(s):$domains_cmd"
            certbot certonly \
                -n \
                --manual \
                --preferred-challenges=dns \
                --manual-auth-hook /var/lib/letsencrypt/hooks/authenticator.sh \
                --manual-cleanup-hook /var/lib/letsencrypt/hooks/cleanup.sh \
                --manual-public-ip-logging-ok \
                --expand \
                --deploy-hook deploy-hook.sh \
                $staging_cmd \
                $domains_cmd
            
            if [ "$containers" != "" ]; then
                echo ">>> Watching certificate for main domain $main_domain: containers $containers autorestarted when certificate is changed."
                echo "[program:${main_domain}_autorestart-containers]" >> /etc/supervisord.d/${main_domain}_autorestart_containers
                echo "command = /scripts/autorestart-containers.sh $main_domain $containers" >> /etc/supervisord.d/${main_domain}_autorestart_containers
                echo "redirect_stderr = true" >> /etc/supervisord.d/${main_domain}_autorestart_containers
                echo "stdout_logfile = /dev/stdout" >> /etc/supervisord.d/${main_domain}_autorestart_containers
                echo "stdout_logfile_maxbytes = 0" >> /etc/supervisord.d/${main_domain}_autorestart_containers
            fi
        done < /etc/letsencrypt/domains.conf

        echo "### Revoke and delete certificates if needed ####"
        for domain in `ls /etc/letsencrypt/live`; do
            remove_domain=true
            while read entry; do
                for comp_domain in $entry; do
                    if [ "$domain" = "$comp_domain" ]; then
                        remove_domain=false
                        break;
                    fi
                done
            done < /etc/letsencrypt/domains.conf

            if [ "$remove_domain" = true ]; then
                echo ">>> Removing the certificate $domain"
                certbot revoke $staging_cmd --cert-path /etc/letsencrypt/live/$domain/cert.pem
                certbot delete $staging_cmd --cert-name $domain
                rm -rf /etc/letsencrypt/live/$domain
            fi
        done

        echo "### Reloading supervisord configuration ###"
        supervisorctl update

        # Keep new hash version
        current_hash="$new_hash"
    fi

    # Wait 1s for next iteration
    sleep 1
done