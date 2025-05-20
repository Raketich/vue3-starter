#!/bin/bash

# Script to collect iOS development certificate, provisioning profile, and team ID
# and prepare them for GitHub Actions secrets

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}   iOS Secrets Collection for GitHub Actions                      ${NC}"
echo -e "${BLUE}==================================================================${NC}"
echo
echo -e "This script will help you collect all necessary secrets for iOS builds in GitHub Actions"
echo

# Prerequisites Section
echo -e "${YELLOW}Prerequisites:${NC}"
echo "1. Xcode must be installed and set up"
echo "2. Command Line Tools must be installed (xcode-select --install)"
echo "3. You must have already created at least one iOS development certificate in Xcode"
echo "4. You must have a provisioning profile for your app"
echo "5. An Apple Developer account (free or paid) associated with your certificates"
echo "6. The apps you build with a free account will expire after 7 days"
echo -e "7. The 'security' and 'openssl' commands must be available\n"

read -p "Do you meet these prerequisites? (y/n): " PREREQ_OK
if [[ $PREREQ_OK != "y" && $PREREQ_OK != "Y" ]]; then
    echo -e "${RED}Please ensure you meet the prerequisites before running this script.${NC}"
    exit 1
fi

# Create a temporary directory for outputs
TEMP_DIR=$(mktemp -d)
echo -e "${YELLOW}Creating temporary directory at ${TEMP_DIR}${NC}"

# New section: Build app to generate provisioning profile if needed
echo -e "\n${GREEN}Optional Step: Generate Provisioning Profile${NC}"
echo -e "If you don't have a provisioning profile yet, we can help build your app to generate one."
read -p "Would you like to initialize and build the app to create a provisioning profile? (y/n): " BUILD_APP
if [[ $BUILD_APP == "y" || $BUILD_APP == "Y" ]]; then
    echo -e "\n${BLUE}=== Generating Provisioning Profile ===${NC}"
    
    # Check if we're in a Tauri project
    if [ -f "src-tauri/tauri.conf.json" ]; then
        echo -e "${GREEN}Detected Tauri project.${NC}"
        
        # Check for required tools
        PACKAGE_MANAGER=""
        if command -v bun &> /dev/null; then
            PACKAGE_MANAGER="bun"
        elif command -v npm &> /dev/null; then
            PACKAGE_MANAGER="npm"
        elif command -v yarn &> /dev/null; then
            PACKAGE_MANAGER="yarn"
        else
            echo -e "${RED}Could not find a suitable package manager (bun, npm, yarn).${NC}"
            echo "Please install dependencies manually and run tauri ios init and build."
            read -p "Press enter to continue with the script anyway (if you have profiles already)..."
        fi
        
        if [ -n "$PACKAGE_MANAGER" ]; then
            # Optionally install dependencies
            read -p "Do you need to install project dependencies first? (y/n): " INSTALL_DEPS
            if [[ $INSTALL_DEPS == "y" || $INSTALL_DEPS == "Y" ]]; then
                echo -e "${BLUE}Installing dependencies...${NC}"
                $PACKAGE_MANAGER install
            fi
            
            # Initialize iOS target
            echo -e "\n${BLUE}Step 1: Initializing iOS target${NC}"
            echo "This will set up the basic Xcode project structure for your app."
            echo "We'll run: $PACKAGE_MANAGER run tauri ios init"
            read -p "Press enter to continue or Ctrl+C to cancel..."
            $PACKAGE_MANAGER run tauri ios init
            
            # Open Xcode project to set up signing
            echo -e "\n${BLUE}Step 2: Opening Xcode project${NC}"
            echo "You need to configure automatic signing in Xcode:"
            echo "1. In the opened Xcode project, select your app target"
            echo "2. Go to the 'Signing & Capabilities' tab"
            echo "3. Check 'Automatically manage signing'"
            echo "4. Select your Personal Team"
            echo "5. Close Xcode after setting up signing"
            read -p "Press enter to open Xcode..."
            XCODE_PROJECT=$(find src-tauri -name "*.xcodeproj" | head -n 1)
            if [ -n "$XCODE_PROJECT" ]; then
                open "$XCODE_PROJECT"
                read -p "Press enter after you've configured signing and closed Xcode..."
            else
                echo -e "${RED}Could not find Xcode project. You may need to manually open it.${NC}"
            fi
            
            # Build the app
            echo -e "\n${BLUE}Step 3: Building iOS app${NC}"
            echo "This will build the app and generate the provisioning profile."
            echo "We'll run: $PACKAGE_MANAGER run tauri ios build --debug"
            read -p "Press enter to continue or Ctrl+C to cancel..."
            $PACKAGE_MANAGER run tauri ios build --debug
            
            echo -e "\n${GREEN}Build completed! A provisioning profile should now be generated.${NC}"
        fi
    else
        echo -e "${YELLOW}Not a Tauri project or not in the root directory.${NC}"
        echo "Please run this script from your project root directory."
        echo "If you're using another framework, you'll need to build your iOS app manually."
        read -p "Press enter to continue with the script anyway (if you have profiles already)..."
    fi
else
    echo -e "${BLUE}Skipping app build, continuing with existing profiles...${NC}"
fi

# Step 1: Find and export Development Certificate
echo -e "\n${GREEN}Step 1: Collecting Development Certificate${NC}"
echo -e "Listing available iOS Development certificates in your keychain...\n"

# List all development certificates
security find-identity -p codesigning -v | grep "iPhone Developer\|Apple Development" || {
    echo -e "${RED}No iOS development certificates found in your keychain.${NC}"
    echo "Please create a development certificate in Xcode before continuing."
    exit 1
}

echo
echo -e "${YELLOW}Which certificate would you like to use? (Enter the number)${NC}"

# Create temp file for certificates with dates
CERT_LIST_FILE="$TEMP_DIR/cert_list.txt"
touch "$CERT_LIST_FILE"

CERTS=()
COUNT=1
while read -r line; do
    CERT_HASH=$(echo "$line" | awk -F'"' '{print $1}' | awk '{print $2}')
    CERT_NAME=$(echo "$line" | sed -n 's/.*"\(.*\)"/\1/p')
    
    # Get certificate details including creation date
    CERT_INFO=$(security find-certificate -c "$CERT_NAME" -p | openssl x509 -noout -startdate -enddate 2>/dev/null)
    CREATED=$(echo "$CERT_INFO" | grep "notBefore" | cut -d= -f2)
    EXPIRES=$(echo "$CERT_INFO" | grep "notAfter" | cut -d= -f2)
    
    CERTS+=("$line")
    echo "$COUNT) $CERT_NAME"
    echo "   Created: $CREATED"
    echo "   Expires: $EXPIRES"
    echo "   Hash: $CERT_HASH"
    echo
    ((COUNT++))
done < <(security find-identity -p codesigning -v | grep "iPhone Developer\|Apple Development")

read -p "Enter the certificate number: " CERT_NUM
CERT_NUM=$((CERT_NUM-1))
SELECTED_CERT="${CERTS[$CERT_NUM]}"

# Extract certificate name
CERT_NAME=$(echo "$SELECTED_CERT" | sed -n 's/.*"\(.*\)"/\1/p')
echo -e "${GREEN}Selected: ${CERT_NAME}${NC}"

# Export certificate to p12
echo -e "\nExporting certificate to P12 file. You'll need to set a password."
echo -e "${YELLOW}REMEMBER THIS PASSWORD as you'll need it for GitHub secrets!${NC}"

P12_FILE="$TEMP_DIR/ios_development.p12"
security export -t identities -f pkcs12 -k ~/Library/Keychains/login.keychain-db -P "" -o "$P12_FILE" "$CERT_NAME"

# Prompt for the password they just set
read -sp "Enter the password you just set for the certificate: " CERT_PASSWORD
echo

# Remove any trailing whitespace or newlines from the password
CERT_PASSWORD=$(echo "$CERT_PASSWORD" | tr -d '\n' | tr -d '\r' | tr -d ' ')
echo -e "\n${YELLOW}Password sanitized to avoid hidden characters.${NC}"
echo -e "Password length: ${#CERT_PASSWORD} characters"
echo -e "Password: '${CERT_PASSWORD}' (surrounded by quotes to show any spaces)"

# Step 3: Find and export Provisioning Profile
echo -e "\n${GREEN}Step 3: Finding Provisioning Profiles${NC}"
echo "Listing all provisioning profiles..."

PROFILES_DIR=~/Library/MobileDevice/Provisioning\ Profiles
if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}No provisioning profiles directory found or directory is empty.${NC}"
    echo "Let's try to find provisioning profiles elsewhere..."
    
    # Find all provisioning profiles in DerivedData 
    ALL_PROFILES=$(find ~/Library/Developer/Xcode/DerivedData -name "*.mobileprovision" 2>/dev/null)
    
    if [ -n "$ALL_PROFILES" ]; then
        # Create a temporary directory to store found profiles
        mkdir -p "$TEMP_DIR/profiles"
        # Copy all found profiles to the temp directory
        count=0
        while IFS= read -r profile; do
            cp "$profile" "$TEMP_DIR/profiles/profile_$count.mobileprovision"
            ((count++))
        done <<< "$ALL_PROFILES"
        
        PROFILES_DIR="$TEMP_DIR/profiles"
        echo -e "Found ${count} profiles and copied to ${GREEN}${PROFILES_DIR}${NC}"
    else
        echo -e "${RED}No provisioning profiles found.${NC}"
        echo "Please generate a provisioning profile in Xcode and try again."
        exit 1
    fi
fi

# List all profiles with details
echo "Available provisioning profiles:"
COUNT=1
declare -a PROFILE_PATHS
declare -a PROFILE_NAMES

while read -r profile; do
    PROFILE_PATHS+=("$profile")
    PROFILE_CONTENT=$(security cms -D -i "$profile" 2>/dev/null)
    PROFILE_NAME=$(echo "$PROFILE_CONTENT" | plutil -extract Name xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null)
    PROFILE_NAMES+=("$PROFILE_NAME")
    PROFILE_TYPE=$(echo "$PROFILE_CONTENT" | grep -A1 "ProvisionsAllDevices" || echo "Development")
    # Extract team ID from the profile
    PROFILE_TEAM_ID=$(echo "$PROFILE_CONTENT" | plutil -extract TeamIdentifier.0 xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null | tr -d '"')
    PROFILE_CREATION=$(echo "$PROFILE_CONTENT" | plutil -extract CreationDate xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null)
    PROFILE_EXPIRY=$(echo "$PROFILE_CONTENT" | plutil -extract ExpirationDate xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null)
    
    echo "$COUNT) $PROFILE_NAME"
    echo "   Team ID: $PROFILE_TEAM_ID"
    echo "   Created: $PROFILE_CREATION"
    echo "   Expires: $PROFILE_EXPIRY"
    echo "   Path: $profile"
    echo
    ((COUNT++))
done < <(find "$PROFILES_DIR" -name "*.mobileprovision" 2>/dev/null)

if [ ${#PROFILE_PATHS[@]} -eq 0 ]; then
    echo -e "${RED}No provisioning profiles found.${NC}"
    echo "Please generate a provisioning profile in Xcode and try again."
    exit 1
fi

echo
read -p "Select a provisioning profile (enter number): " PROFILE_NUM
PROFILE_NUM=$((PROFILE_NUM-1))
SELECTED_PROFILE="${PROFILE_PATHS[$PROFILE_NUM]}"
SELECTED_PROFILE_NAME="${PROFILE_NAMES[$PROFILE_NUM]}"

echo -e "Selected profile: ${GREEN}${SELECTED_PROFILE_NAME}${NC}"

# Copy the selected profile
PROFILE_FILE="$TEMP_DIR/profile.mobileprovision"
cp "$SELECTED_PROFILE" "$PROFILE_FILE"

# Step 2: Extract Team ID from the selected provisioning profile (more reliable)
echo -e "\n${GREEN}Step 2: Extracting Team ID${NC}"
PROFILE_CONTENT=$(security cms -D -i "$PROFILE_FILE" 2>/dev/null)
TEAM_ID=$(echo "$PROFILE_CONTENT" | plutil -extract TeamIdentifier.0 xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null | tr -d '"')

if [ -z "$TEAM_ID" ]; then
    echo -e "${YELLOW}Could not automatically find Team ID from provisioning profile.${NC}"
    read -p "Please enter your Apple Team ID manually: " TEAM_ID
else
    echo -e "Found Team ID: ${GREEN}${TEAM_ID}${NC}"
fi

# Step 4: Convert to base64
echo -e "\n${GREEN}Step 4: Converting files to base64 for GitHub secrets${NC}"

# Ensure base64 output has NO line breaks or invisible characters (this is critical for GitHub Actions)
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS base64 output needs to be piped through tr to remove newlines
    P12_BASE64=$(base64 -i "$P12_FILE" | tr -d '\n')
    PROFILE_BASE64=$(base64 -i "$PROFILE_FILE" | tr -d '\n')
else
    # Linux base64 can use -w0 for no wrapping
    P12_BASE64=$(base64 -w0 -i "$P12_FILE")
    PROFILE_BASE64=$(base64 -w0 -i "$PROFILE_FILE")
fi

# Confirm there are no newlines in the encoding
if echo "$P12_BASE64" | grep -q $'\n'; then
    echo -e "${RED}WARNING: Newlines detected in certificate base64 - fixing...${NC}"
    P12_BASE64=$(echo "$P12_BASE64" | tr -d '\n')
fi

if echo "$PROFILE_BASE64" | grep -q $'\n'; then
    echo -e "${RED}WARNING: Newlines detected in profile base64 - fixing...${NC}"
    PROFILE_BASE64=$(echo "$PROFILE_BASE64" | tr -d '\n')
fi

# Verify base64 encoding worked and has no line breaks
P12_LEN=${#P12_BASE64}
PROFILE_LEN=${#PROFILE_BASE64}
echo -e "${BLUE}Certificate base64 length: ${P12_LEN} characters (should be one continuous string)${NC}"
echo -e "${BLUE}Profile base64 length: ${PROFILE_LEN} characters (should be one continuous string)${NC}"

# Verify certificate can be decoded properly
TEMP_P12="$TEMP_DIR/verify_cert.p12"
echo "$P12_BASE64" | base64 -d > "$TEMP_P12" 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Certificate base64 verification: SUCCESS${NC}"
    # Check if openssl can read the cert
    if openssl pkcs12 -in "$TEMP_P12" -noout -passin "pass:$CERT_PASSWORD" 2>/dev/null; then
        echo -e "${GREEN}Certificate password verification: SUCCESS${NC}"
    else
        echo -e "${RED}Certificate password verification: FAILED${NC}"
        echo -e "${RED}The password doesn't appear to work with the certificate.${NC}"
        echo -e "${YELLOW}Try again with a simpler password with only alphanumeric characters.${NC}"
    fi
else
    echo -e "${RED}Certificate base64 verification: FAILED${NC}"
    echo -e "${RED}The base64 encoding might have issues.${NC}"
fi

# Generate output file
OUTPUT_FILE="$TEMP_DIR/github_secrets.txt"
{
    echo "# GitHub Secrets for iOS builds"
    echo "# Generated on $(date)"
    echo 
    echo "# 1. Add these secrets to your GitHub repository at:"
    echo "#    Settings > Secrets and variables > Actions > New repository secret"
    echo
    echo "# Apple Team ID"
    echo "APPLE_TEAM_ID=$TEAM_ID"
    echo
    echo "# iOS Development Certificate (IMPORTANT: ADD AS ONE CONTINUOUS STRING WITH NO LINE BREAKS)"
    echo "IOS_DEVELOPMENT_CERTIFICATE=$P12_BASE64"
    echo
    echo "# Certificate Password"
    echo "IOS_DEVELOPMENT_CERTIFICATE_PASSWORD=$CERT_PASSWORD"
    echo
    echo "# IMPORTANT: Verify this password length matches what you expect: ${#CERT_PASSWORD} characters"
    echo
    echo "# Provisioning Profile (IMPORTANT: ADD AS ONE CONTINUOUS STRING WITH NO LINE BREAKS)"
    echo "IOS_ADHOC_PROVISIONING_PROFILE=$PROFILE_BASE64"
    echo
    echo "# GitHub Action Debug Code"
    echo "# Add this to your workflow to debug certificate issues:"
    echo "      - name: Debug Certificate Issues"
    echo "        run: |"
    echo "          echo \"Certificate length check (should be non-zero):\""
    echo "          [[ -n \"\$IOS_DEVELOPMENT_CERTIFICATE\" ]] && echo \"Certificate exists and is not empty\" || echo \"Certificate is EMPTY!\""
    echo "          echo \"Certificate length:     \${#IOS_DEVELOPMENT_CERTIFICATE} characters\""
    echo "          echo \"Password length check (should be non-zero):\""
    echo "          [[ -n \"\$IOS_DEVELOPMENT_CERTIFICATE_PASSWORD\" ]] && echo \"Password exists and is not empty\" || echo \"Password is EMPTY!\""
    echo "          echo \"Password length:       \${#IOS_DEVELOPMENT_CERTIFICATE_PASSWORD} characters\""
    echo "          echo \"Provisioning profile check (should be non-zero):\""
    echo "          [[ -n \"\$IOS_ADHOC_PROVISIONING_PROFILE\" ]] && echo \"Provisioning profile exists and is not empty\" || echo \"Profile is EMPTY!\""
    echo "          echo \"Profile length:    \${#IOS_ADHOC_PROVISIONING_PROFILE} characters\""
    echo
    echo "          # Test base64 decoding of the certificate"
    echo "          echo \"Testing if certificate can be properly decoded from base64:\""
    echo "          echo \"\$IOS_DEVELOPMENT_CERTIFICATE\" | base64 -d > /tmp/test_cert.p12"
    echo "          echo \"Decoded certificate size: \$(wc -c < /tmp/test_cert.p12) bytes\""
    echo "          echo \"Certificate file type:\""
    echo "          file /tmp/test_cert.p12"
    echo "          # Test password (this may fail but confirms if password is being read)"
    echo "          echo \"Testing certificate with password (will likely fail, but shows if password is being processed):\""
    echo "          [[ -n \"\$IOS_DEVELOPMENT_CERTIFICATE_PASSWORD\" ]] && echo \"Password starts with: \${IOS_DEVELOPMENT_CERTIFICATE_PASSWORD:0:3}...\""
    echo
    echo "      # If the password has any extra chars, use this step to clean it:"
    echo "      - name: Trim any whitespace or newlines from the password and store in environment"
    echo "        run: |"
    echo "          echo \"Original password length: \${#IOS_DEVELOPMENT_CERTIFICATE_PASSWORD} characters\""
    echo "          CLEAN_PASSWORD=\$(echo \"\$IOS_DEVELOPMENT_CERTIFICATE_PASSWORD\" | tr -d '\n' | tr -d '\r' | tr -d ' ')"
    echo "          echo \"Cleaned password length: \${#CLEAN_PASSWORD} characters\""
    echo "          echo \"IOS_DEVELOPMENT_CERTIFICATE_PASSWORD=\$CLEAN_PASSWORD\" >> \$GITHUB_ENV"
    echo
} > "$OUTPUT_FILE"

# Output results
echo -e "\n${BLUE}==================================================================${NC}"
echo -e "${GREEN}All done! GitHub secrets have been generated at:${NC}"
echo -e "${YELLOW}$OUTPUT_FILE${NC}"
echo -e "\n${BLUE}Instructions:${NC}"
echo "1. Go to your GitHub repository"
echo "2. Navigate to Settings > Secrets and variables > Actions"
echo "3. Add each secret from the generated file"
echo "4. Follow the format: Name = Value (copy everything after the = sign)"
echo
echo -e "${RED}IMPORTANT NOTES FOR GITHUB ACTIONS:${NC}"
echo "• Ensure each secret is copied WITHOUT any line breaks"
echo "• For certificate and profile values, copy the ENTIRE string as one continuous line"
echo "• For the password, make sure there are no trailing spaces or newlines"
echo "• Password length: ${#CERT_PASSWORD} characters - verify this matches what you expect!"
echo "• If copying manually, make sure the browser doesn't add hidden characters"
echo "• Copy directly from terminal if possible, or use a text editor that shows hidden characters"
echo "• If you encounter 'MAC verification failed' errors, re-run this script and try again"
echo "• These secrets are sensitive - delete the output file after use!"
echo -e "${BLUE}==================================================================${NC}"

# Information about script portability
echo -e "\n${BLUE}About This Script:${NC}"
echo "- This script can be run from any directory on a Mac"
echo "- Works on both Intel Macs and Apple Silicon (M1/M2/M3) Macs"
echo "- It can be shared with other developers who need to set up iOS build secrets"
echo "- Only requires standard macOS tools (security, openssl, etc.)"
echo "- The generated secrets are specific to one Apple Developer account"
echo "- No special permissions required beyond access to the certificates in your keychain"
echo "- The script doesn't modify any system files or send data anywhere"
echo "- GitHub secrets created with this script work with both self-hosted and GitHub-hosted runners"

# Offer to view the file
read -p "Would you like to view the secrets file now? (y/n): " VIEW_FILE
if [[ $VIEW_FILE == "y" || $VIEW_FILE == "Y" ]]; then
    cat "$OUTPUT_FILE"
fi

# Offer to clean up
read -p "Would you like to delete the temporary files now? (y/n): " CLEANUP
if [[ $CLEANUP == "y" || $CLEANUP == "Y" ]]; then
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}Temporary files deleted.${NC}"
else
    echo -e "${YELLOW}Remember to delete $TEMP_DIR when you're done!${NC}"
fi

echo -e "\n${GREEN}Script complete!${NC}" 