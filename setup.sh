#!/bin/bash

# Ensure the script is run as sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as sudo. Please rerun the script using 'sudo ./setup.sh'"
    exit 1
fi

# Main setup script
setup_type=""
project_name=""
project_path=""

# Spinner function
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinner="|/-\\"

    while [ -d /proc/$pid ]; do
        for i in $(seq 0 3); do
            printf "\r[%c] Working..." "${spinner:$i:1}"
            sleep $delay
        done
    done
    printf "\r[✔] Done!           \n"
}

# Function to check ACL package
check_acl() {
    if ! command -v setfacl &>/dev/null; then
        echo "ACL package not found. Installing..."
        sudo apt update &>/dev/null &
        show_spinner $!
        sudo apt install -y acl &>/dev/null &
        show_spinner $!
    else
        echo "ACL package is already installed."
    fi
}

# Function to check Git installation
check_git() {
    if ! command -v git &>/dev/null; then
        echo "Git is not installed. Installing..."
        sudo apt update &>/dev/null &
        show_spinner $!
        sudo apt install -y git &>/dev/null &
        show_spinner $!
    else
        echo "Git is already installed."
    fi
}

# Function to setup Virtual Host for existing project
existing_project() {
    echo "Enter the project name (no spaces allowed):"
    read project_name

    if [[ $project_name =~ \  ]]; then
        echo "Project name cannot contain spaces. Aborting."
        exit 1
    fi

    # Check if the project name already exists in Apache configuration
    vhost_path="/etc/apache2/sites-available/${project_name}.conf"
    if [ -f "$vhost_path" ]; then
        echo "A virtual host configuration for '${project_name}' already exists. Aborting."
        exit 1
    fi

    # Check if the project name is already in /etc/hosts
    if grep -q "${project_name}.test" /etc/hosts; then
        echo "The hostname '${project_name}.test' already exists in /etc/hosts. Aborting."
        exit 1
    fi

    # Check if the project path exists
    while true; do
        echo "Enter the full path to the Laravel project (e.g., /home/user/Projects/my-laravel-project or /var/www/my-laravel-project):"
        read project_path

        # Expand ~ to the full home path
        project_path=${project_path/#\~/$HOME}

        if [ -d "$project_path" ]; then
            break
        else
            echo "The specified path does not exist. Please enter a valid path."
        fi
    done

    # Check if the path is outside /var/www
    if [[ $project_path != /var/www* ]]; then
        echo "Setting permissions for a project outside /var/www..."

        check_acl

        echo "Changing group ownership to www-data..."
        sudo chgrp -R www-data "$project_path" &>/dev/null &
        show_spinner $!

        echo "Setting writable permissions for storage and cache directories..."
        sudo chmod -R 775 "$project_path/storage" "$project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!

        echo "Applying ACL permissions..."
        sudo setfacl -R -m u:www-data:rwx "$project_path/storage" "$project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!
        sudo setfacl -dR -m u:www-data:rwx "$project_path/storage" "$project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!
    else
        echo "Setting permissions for a project inside /var/www..."

        sudo chmod -R 775 "$project_path/storage" "$project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!
    fi

    # Create virtual host configuration
    echo "Creating virtual host configuration..."
    cat <<EOF | sudo tee "$vhost_path" &>/dev/null &
<VirtualHost *:80>
    ServerAdmin admin@${project_name}.test
    ServerName ${project_name}.test
    DocumentRoot ${project_path}/public

    <Directory ${project_path}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    show_spinner $!

    # Enable the site and test Apache configuration
    echo "Testing Apache configuration..."
    sudo apache2ctl configtest &>/dev/null &
    show_spinner $!
    if [ $? -eq 0 ]; then
        echo "Enabling the virtual host..."
        sudo a2ensite "${project_name}.conf" &>/dev/null &
        show_spinner $!

        echo "Adding entry to /etc/hosts..."
        echo "127.0.0.1   ${project_name}.test" | sudo tee -a /etc/hosts &>/dev/null &
        show_spinner $!

        echo "Restarting Apache..."
        sudo systemctl restart apache2 &>/dev/null &
        show_spinner $!

        echo "Virtual host setup complete. You can now access http://${project_name}.test"
    else
        echo "Apache configuration test failed. Please check the virtual host file."
    fi
}

# Function to setup new project with git
setup_with_git() {
    # Check Git installation
    echo "Checking Git installation..."
    check_git &>/dev/null &
    show_spinner $!

    # Ask for Git repository link
    echo "Enter the Git repository link:"
    read git_repo

    if [[ -z "$git_repo" ]]; then
        echo "Git repository link cannot be empty. Aborting."
        exit 1
    fi

    # Ask for the clone path
    echo "Enter the full path where the project should be cloned (e.g., /home/user/Projects):"
    read project_path

    # Check if the project path exists
    # Expand ~ to the full home path
    project_path=${project_path/#\~/$HOME}

    if [ ! -d "$project_path" ]; then
        echo "The specified path does not exist. Creating it..."
        mkdir -p "$project_path" &>/dev/null &
        show_spinner $!
    fi

    # Ask for the project name
    echo "Enter the project name (no spaces allowed):"
    read project_name

    if [[ $project_name =~ \  ]]; then
        echo "Project name cannot contain spaces. Aborting."
        exit 1
    fi

    # Check if the project name already exists in Apache configuration
    vhost_path="/etc/apache2/sites-available/${project_name}.conf"
    if [ -f "$vhost_path" ]; then
        echo "A virtual host configuration for '${project_name}' already exists. Aborting."
        exit 1
    fi

    # Check if the project name is already in /etc/hosts
    if grep -q "${project_name}.test" /etc/hosts; then
        echo "The hostname '${project_name}.test' already exists in /etc/hosts. Aborting."
        exit 1
    fi

    # Clone the repository
    echo "Cloning the repository..."
    git clone "$git_repo" "$project_path/$project_name" &>/dev/null &
    show_spinner $!

    if [ $? -ne 0 ]; then
        echo "Failed to clone the repository. Aborting."
        exit 1
    fi

    echo "Repository successfully cloned to $project_path/$project_name."

    # Set permissions
    full_project_path="$project_path/$project_name"
    if [[ $full_project_path != /var/www* ]]; then
        echo "Setting permissions for a project outside /var/www..."

        echo "Changing group ownership to www-data..."
        sudo chgrp -R www-data "$full_project_path" &>/dev/null &
        show_spinner $!

        echo "Setting writable permissions for storage and cache directories..."
        sudo chmod -R 775 "$full_project_path/storage" "$full_project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!

        echo "Applying ACL permissions..."
        sudo setfacl -R -m u:www-data:rwx "$full_project_path/storage" "$full_project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!
        sudo setfacl -dR -m u:www-data:rwx "$full_project_path/storage" "$full_project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!
    else
        echo "Setting permissions for a project inside /var/www..."

        sudo chmod -R 775 "$full_project_path/storage" "$full_project_path/bootstrap/cache" &>/dev/null &
        show_spinner $!
    fi

    # Create virtual host configuration
    echo "Creating virtual host configuration..."
    vhost_path="/etc/apache2/sites-available/${project_name}.conf"
    cat <<EOF | sudo tee "$vhost_path" &>/dev/null &
<VirtualHost *:80>
    ServerAdmin admin@${project_name}.test
    ServerName ${project_name}.test
    DocumentRoot ${full_project_path}/public

    <Directory ${full_project_path}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
    show_spinner $!

    # Enable the site and test Apache configuration
    echo "Testing Apache configuration..."
    sudo apache2ctl configtest &>/dev/null &
    show_spinner $!
    if [ $? -eq 0 ]; then
        echo "Enabling the virtual host..."
        sudo a2ensite "${project_name}.conf" &>/dev/null &
        show_spinner $!

        echo "Adding entry to /etc/hosts..."
        echo "127.0.0.1   ${project_name}.test" | sudo tee -a /etc/hosts &>/dev/null &
        show_spinner $!

        echo "Restarting Apache..."
        sudo systemctl restart apache2 &>/dev/null &
        show_spinner $!

        echo "Virtual host setup complete. You can now access http://${project_name}.test"
    else
        echo "Apache configuration test failed. Please check the virtual host file."
    fi
}

# Main Menu
echo "Select the type of project setup:"
echo "1. Laravel"
echo "Press any other key to cancel."
read setup_type

# Check if the input is empty
if [[ "$setup_type" != "1" ]]; then
    echo "Setup canceled."
    exit 0
fi

echo "Select the action:"
echo "1. Setup Virtual Host for existing project"
echo "2. Setup new project with git"
echo "Press any other key to cancel."
read action

case $action in
1)
    existing_project
    ;;
2)
    setup_with_git
    ;;
*)
    echo "Setup canceled."
    exit 0
    ;;
esac
