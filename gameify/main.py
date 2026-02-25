import paramiko
import os
import argparse

def ssh_to_bastion(bastion_host, bastion_port, bastion_user, password, command, output_file):
    """
    SSHs into a bastion host, runs a command, and returns the output from a file.

    :param bastion_host: IP or hostname of the bastion host
    :param bastion_port: SSH port of the bastion host (default 22)
    :param bastion_user: Username to SSH into the bastion host
    :param password: Password for SSH authentication
    :param command: The command or script to run on the bastion host
    :param output_file: The file to write the output to on the bastion host
    :return: The output from the command executed
    """
    
    # Initialize SSH client
    ssh_client = paramiko.SSHClient()
    
    # Auto add host key (make sure to use appropriate key checking in production)
    ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        # Connect to the bastion host using password authentication
        ssh_client.connect(bastion_host, bastion_port, bastion_user, password=password)
        
        # Run the command on the bastion host
        stdin, stdout, stderr = ssh_client.exec_command(command)
        
        # Wait for the command to complete
        stdout.channel.recv_exit_status()  # Wait until the command finishes
        
        # Fetch the output file using SFTP
        sftp_client = ssh_client.open_sftp()
        sftp_client.get(output_file, "bastion_output_local.log")  # Download the file locally
        sftp_client.close()

        # Close the SSH connection
        ssh_client.close()

        # Read the output from the local file
        with open("bastion_output_local.log", 'r') as file:
            output = file.read()

        return output
    except Exception as e:
        return f"Connection failed: {e}"

def main():
    # Set up argument parser — all connection options required for container/lab variability
    parser = argparse.ArgumentParser(description="SSH to Bastion Host and run a command.")
    parser.add_argument('-H', '--hostname', type=str, required=True,
                        help="Bastion host IP or hostname (e.g. ssh.ocpv06.rhdp.net)")
    parser.add_argument('-p', '--port', type=int, required=True,
                        help="SSH port (e.g. 32751 for lab)")
    parser.add_argument('-u', '--user', type=str, required=True,
                        help="SSH username (e.g. lab-user)")
    parser.add_argument('-P', '--password', type=str, required=True,
                        help="Password for SSH authentication")

    # Parse the command-line arguments
    args = parser.parse_args()

    bastion_host = args.hostname
    bastion_port = args.port
    bastion_user = args.user
    password = args.password

    # Path to the output file on the bastion host (uses SSH user for home dir)
    output_folder = f"/home/{bastion_user}/tests/"
    output_file = f"/home/{bastion_user}/tests/bastion_output.log"

    # Bash commands to run on the bastion host
    command = f"""
    mkdir -p {output_folder}
    touch {output_file}
    sleep 1  # Add sleep to allow previous commands to finish
    echo "Starting script execution..." > {output_file}
    sleep 1  # Add sleep to allow previous commands to finish

    # Ensure ROX_CENTRAL_ADDRESS is set in .bashrc (host only, no scheme) so curl URL works
    if ! grep -q 'ROX_CENTRAL_ADDRESS=' ~/.bashrc 2>/dev/null; then
        echo 'export ROX_CENTRAL_ADDRESS="${{ACS_ROUTE#https://}}" ; ROX_CENTRAL_ADDRESS="${{ROX_CENTRAL_ADDRESS#http://}}"' >> ~/.bashrc
    fi
    source ~/.bashrc 2>/dev/null || true
    [ -n "$ROX_CENTRAL_ADDRESS" ] || {{ export ROX_CENTRAL_ADDRESS="${{ACS_ROUTE#https://}}" ; ROX_CENTRAL_ADDRESS="${{ROX_CENTRAL_ADDRESS#http://}}" ; export ROX_CENTRAL_ADDRESS ; }}

    # Install jq if not present (for API response parsing)
    if ! command -v jq &>/dev/null; then
        if command -v dnf &>/dev/null; then
            sudo dnf install -y jq 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            sudo yum install -y jq 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            sudo apt-get update -qq 2>/dev/null; sudo apt-get install -y jq 2>/dev/null || true
        fi
    fi

    # Check that frontend pods are deployed and running in patient-portal
    out=$(oc get pods -n patient-portal --no-headers 2>&1)
    if echo "$out" | grep '^frontend-' | grep -q 'Running'; then
        echo "Module 0 success" >> {output_file}
    else
        echo "Module 0 failed" >> {output_file}
    fi
    echo "Module 0 output:" >> {output_file}
    echo "$out" >> {output_file}
    echo "---" >> {output_file}

    # Check if the policy is finished (filter by name, get ID)
    out=$(curl --insecure -s -X GET https://$ROX_CENTRAL_ADDRESS/v1/policies \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" 2>&1)
    policy_id=$(echo "$out" | jq -r '.policies[] | select(.name == "finished-1-policy") | .id' 2>&1)
    if [ -n "$policy_id" ]; then
        echo "Module 1 success" >> {output_file}
    else
        echo "Module 1 failed" >> {output_file}
    fi
    echo "Module 1 output (finished-1-policy id):" >> {output_file}
    echo "$policy_id" >> {output_file}
    echo "---" >> {output_file}

    # Check if the vulnerability report "frontend-vuln-report" exists (v2 report configurations API)
    out=$(curl --insecure -s -X GET "https://$ROX_CENTRAL_ADDRESS/v2/reports/configurations" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" 2>&1)
    report_id=$(echo "$out" | jq -r '.reportConfigs[] | select(.name == "frontend-vuln-report") | .id' 2>&1)
    if [ -n "$report_id" ]; then
        echo "Module 2 success" >> {output_file}
    else
        echo "Module 2 failed" >> {output_file}
    fi
    echo "Module 2 output (frontend-vuln-report id):" >> {output_file}
    echo "$report_id" >> {output_file}
    echo "---" >> {output_file}

    # Check if the policy is finished
    out=$(curl --insecure -s -w "%{{http_code}}" -X GET https://$ROX_CENTRAL_ADDRESS/v1/reports \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" 2>&1)
    code="${{out##*$'\n'}}"
    body="${{out%$'\n'*}}"
    if [ "$code" = "200" ]; then
        echo "Module 3 success" >> {output_file}
    else
        echo "Module 3 failed" >> {output_file}
    fi
    echo "Module 3 output (http $code):" >> {output_file}
    echo "$body" >> {output_file}
    echo "---" >> {output_file}

    # Check if the Alpine policy exists (filter by name, get ID)
    out=$(curl --insecure -s -X GET https://$ROX_CENTRAL_ADDRESS/v1/policies \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" 2>&1)
    policy_id=$(echo "$out" | jq -r '.policies[] | select(.name == "Alpine Linux Package Manager in Image - Enforce Build") | .id' 2>&1)
    if [ -n "$policy_id" ]; then
        echo "Module 4 success" >> {output_file}
    else
        echo "Module 4 failed" >> {output_file}
    fi
    echo "Module 4 output (Alpine policy id):" >> {output_file}
    echo "$policy_id" >> {output_file}
    echo "---" >> {output_file}


    # Check TaskRun status for succeeded tasks
    out=$(oc get taskrun -n pipeline-demo -o json 2>&1)
    taskruns=$(echo "$out" | jq -r '.items[] | select(.status.succeeded == true) | .metadata.name' 2>&1)
    if [ -z "$taskruns" ]; then
        eq=1
    else
        eq=0
    fi
    if [ $eq -eq 0 ]; then
        echo "Module 5 success" >> {output_file}
    else
        echo "Module 5 failed" >> {output_file}
    fi
    echo "Module 5 output (succeeded taskruns):" >> {output_file}
    echo "$taskruns" >> {output_file}
    echo "---" >> {output_file}

    # Check if the compliance scan was created
    out=$(curl --insecure -s -w "
%{{http_code}}" -X GET "https://$ROX_CENTRAL_ADDRESS/v2/compliance/scan/results" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" 2>&1)
    code="${{out##*$'\n'}}"
    body="${{out%$'\n'*}}"
    if [ "$code" = "200" ]; then
        echo "Module 6 success" >> {output_file}
    else
        echo "Module 6 failed" >> {output_file}
    fi
    echo "Module 6 output (http $code):" >> {output_file}
    echo "$body" >> {output_file}
    echo "---" >> {output_file}

    # If all commands succeed, print completion
    echo "Completion" >> {output_file}
    """

    # Run under bash so .bashrc is sourced and ROX_* variables are set.
    # Use bash -c $'...' so newlines are preserved over SSH.
    escaped = command.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n").replace("\r", "\\r")
    full_command = "bash -c $" + "'" + escaped + "'"

    # Run the command and capture output
    result = ssh_to_bastion(bastion_host, bastion_port, bastion_user, password, full_command, output_file)
    
    # Print result to console
    print("Output from bastion host:")
    print(result)

if __name__ == "__main__":
    main()
