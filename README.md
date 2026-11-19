# frappe-15-prod

### Production steps
0. After frappe site is running login and boostrap admin
1. Run script to install the site: /scripts/site_init.sh
2. Manually install the apps you want from their sources
3. To back up and drop the site, run /scripts/site_drop.sh (use --force to confirm non-interactively).
4. To uninstall an app interactively, run /scripts/uninstall_app.sh.
5. # frappe-15-prod
