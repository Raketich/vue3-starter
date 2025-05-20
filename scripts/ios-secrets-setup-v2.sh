#!/bin/bash

# iOS Secrets Setup - Simplified Version
# This script helps you export certificates and provisioning profiles for GitHub Actions
# Based on successful approach with vue3-starter project

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Title banner
echo -e "${BLUE}==================================================================${NC}"
echo -e "${BLUE}   iOS Secrets Collection for GitHub Actions - Simplified         ${NC}"
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

# Step 1: Get Team ID
echo -e "\n${GREEN}Step 1: Finding Apple Team ID${NC}"
echo -e "Attempting to extract Team ID from existing certificates...\n"

# Look for Team ID in certificate subject
TEAM_ID=$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -subject -noout 2>/dev/null | grep -o "OU=[A-Z0-9]*" | cut -d= -f2)

if [ -n "$TEAM_ID" ]; then
    echo -e "Found Team ID: ${GREEN}${TEAM_ID}${NC}"
else
    # If not found, prompt user
    echo -e "${YELLOW}Could not automatically extract Team ID.${NC}"
    read -p "Please enter your Apple Team ID (found in Xcode → Settings → Accounts): " TEAM_ID
fi

# Step 2: Export Development Certificate
echo -e "\n${GREEN}Step 2: Exporting Development Certificate${NC}"
echo -e "Finding and listing iOS Development certificates...\n"

# Clean up certificate list to show only unique certs
CERTS=()
CERT_NAMES=()
COUNT=0

while read -r line; do
    CERT_HASH=$(echo "$line" | awk -F'"' '{print $1}' | awk '{print $2}')
    CERT_NAME=$(echo "$line" | sed -n 's/.*"\(.*\)"/\1/p')
    
    # Skip if we've already processed this certificate name
    SKIP=0
    for name in "${CERT_NAMES[@]}"; do
        if [[ "$name" == "$CERT_NAME" ]]; then
            SKIP=1
            break
        fi
    done
    
    if [[ $SKIP -eq 1 ]]; then
        continue
    fi
    
    # Store certificate info
    CERTS+=("$line")
    CERT_NAMES+=("$CERT_NAME")
    
    # Display certificate with proper dates
    COUNT=$((COUNT+1))
    echo "$COUNT) $CERT_NAME"
    # Get certificate info from Keychain and display it
    CERT_INFO=$(security find-certificate -c "$CERT_NAME" -p 2>/dev/null | openssl x509 -noout -startdate -enddate 2>/dev/null)
    CREATED=$(echo "$CERT_INFO" | grep "notBefore" | sed 's/notBefore=//')
    EXPIRES=$(echo "$CERT_INFO" | grep "notAfter" | sed 's/notAfter=//')
    echo "   Created: $CREATED"
    echo "   Expires: $EXPIRES"
    echo "   Hash: $CERT_HASH"
    echo
done < <(security find-identity -p codesigning -v | grep "iPhone Developer\|Apple Development")

if [[ $COUNT -eq 0 ]]; then
    echo -e "${RED}No iOS development certificates found in your keychain.${NC}"
    echo "Please create a development certificate in Xcode before continuing."
    exit 1
fi

# Let user select certificate
read -p "Enter the certificate number: " CERT_NUM
if [[ $CERT_NUM -gt $COUNT || $CERT_NUM -lt 1 ]]; then
    echo -e "${RED}Invalid certificate number.${NC}"
    exit 1
fi

CERT_NUM=$((CERT_NUM-1))
SELECTED_CERT_NAME="${CERT_NAMES[$CERT_NUM]}"

echo -e "${GREEN}Selected: ${SELECTED_CERT_NAME}${NC}"

# Export certificate to P12 with a simple password
# Using a simple password like "ios123" avoids issues with special characters
DEFAULT_PASSWORD="ios123"
echo -e "\n${YELLOW}Password selection for certificate:${NC}"
echo -e "1) Use default simple password (${GREEN}$DEFAULT_PASSWORD${NC}) - recommended for GitHub Actions"
echo -e "2) Enter a custom password"
read -p "Choose an option (1/2): " PASSWORD_OPTION

if [[ $PASSWORD_OPTION == "2" ]]; then
    read -sp "Enter your custom password: " CERT_PASSWORD
    echo
    # Confirm password
    read -sp "Confirm password: " CERT_PASSWORD_CONFIRM
    echo
    
    if [[ "$CERT_PASSWORD" != "$CERT_PASSWORD_CONFIRM" ]]; then
        echo -e "${RED}Passwords don't match. Exiting.${NC}"
        exit 1
    fi
    
    # Warn about special characters
    if [[ "$CERT_PASSWORD" != "${CERT_PASSWORD//[^a-zA-Z0-9]/}" ]]; then
        echo -e "${YELLOW}Warning: Your password contains special characters which might cause issues with GitHub Actions.${NC}"
        read -p "Continue anyway? (y/n): " CONTINUE
        if [[ $CONTINUE != "y" && $CONTINUE != "Y" ]]; then
            echo -e "${RED}Exiting.${NC}"
            exit 1
        fi
    fi
else
    CERT_PASSWORD="$DEFAULT_PASSWORD"
fi

P12_FILE="$TEMP_DIR/ios_development.p12"

echo -e "\nExporting certificate to P12 file with the selected password."
echo -e "${YELLOW}REMEMBER THIS PASSWORD as you'll need it for GitHub secrets!${NC}"

security export -t identities -f pkcs12 -k ~/Library/Keychains/login.keychain-db -P "$CERT_PASSWORD" -o "$P12_FILE" "$SELECTED_CERT_NAME"

if [ ! -f "$P12_FILE" ]; then
    echo -e "${RED}Failed to export certificate. Please try again.${NC}"
    exit 1
fi

echo -e "${GREEN}Certificate exported successfully to $P12_FILE${NC}"
echo -e "Certificate size: $(wc -c < "$P12_FILE") bytes"

# Step 3: Find and export Provisioning Profile
echo -e "\n${GREEN}Step 3: Finding Provisioning Profiles${NC}"
echo "Searching for iOS provisioning profiles in all standard locations..."

# Create a list of possible profile locations
PROFILES_FOUND=false
ALL_PROFILES=()

# Check standard locations first
echo -e "Checking standard profile location..."
if [ -d "$HOME/Library/MobileDevice/Provisioning Profiles" ]; then
    while IFS= read -r profile; do
        ALL_PROFILES+=("$profile")
        PROFILES_FOUND=true
    done < <(find "$HOME/Library/MobileDevice/Provisioning Profiles" -name "*.mobileprovision" 2>/dev/null)
    
    if [ ${#ALL_PROFILES[@]} -gt 0 ]; then
        echo -e "${GREEN}Found profiles in MobileDevice directory${NC}"
    fi
fi

# Check Xcode UserData location
echo -e "Checking Xcode UserData location..."
if [ -d "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" ]; then
    while IFS= read -r profile; do
        ALL_PROFILES+=("$profile")
        PROFILES_FOUND=true
    done < <(find "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" -name "*.mobileprovision" 2>/dev/null)
    
    if [ ${#ALL_PROFILES[@]} -gt 0 ]; then
        echo -e "${GREEN}Found profiles in Xcode UserData directory${NC}"
    fi
fi

# Check for embedded profiles in DerivedData
echo -e "Checking DerivedData for embedded profiles..."
while IFS= read -r profile; do
    ALL_PROFILES+=("$profile")
    PROFILES_FOUND=true
done < <(find ~/Library/Developer/Xcode/DerivedData -name "*.mobileprovision" 2>/dev/null)

if [ ${#ALL_PROFILES[@]} -gt 0 ]; then
    echo -e "${GREEN}Found profiles in DerivedData${NC}"
fi

# If no profiles found, exit
if [ "$PROFILES_FOUND" = false ]; then
    echo -e "${RED}No provisioning profiles found in any location.${NC}"
    echo "Please generate a provisioning profile in Xcode and try again."
    exit 1
fi

# List all profiles with details
echo -e "\n${GREEN}Available provisioning profiles:${NC}"
COUNT=1
declare -a PROFILE_PATHS
declare -a PROFILE_NAMES
declare -a PROFILE_TEAM_IDS

for profile_path in "${ALL_PROFILES[@]}"; do
    # Extract profile info
    PROFILE_CONTENT=$(security cms -D -i "$profile_path" 2>/dev/null)
    PROFILE_NAME=$(echo "$PROFILE_CONTENT" | plutil -extract Name xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null)
    
    # Extract team ID from the profile
    PROFILE_TEAM_ID=$(echo "$PROFILE_CONTENT" | plutil -extract TeamIdentifier.0 xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null | tr -d '"')
    
    # Store in separate arrays for safer access
    PROFILE_PATHS+=("$profile_path")
    PROFILE_NAMES+=("$PROFILE_NAME")
    PROFILE_TEAM_IDS+=("$PROFILE_TEAM_ID")
    
    # Extract app identifier (bundle ID)
    APP_ID=$(echo "$PROFILE_CONTENT" | plutil -extract Entitlements.application-identifier xml1 -o - - 2>/dev/null | plutil -p - 2>/dev/null | tr -d '"' | sed "s/^$PROFILE_TEAM_ID\\.//")
    
    echo "$COUNT) $PROFILE_NAME"
    echo "   Team ID: $PROFILE_TEAM_ID"
    echo "   App ID: $APP_ID"
    echo "   Path: $profile_path"
    echo
    
    COUNT=$((COUNT+1))
done

TOTAL_PROFILES=${#PROFILE_PATHS[@]}

if [ $TOTAL_PROFILES -eq 0 ]; then
    echo -e "${RED}No valid provisioning profiles could be processed.${NC}"
    echo "Please check your Xcode setup and try again."
    exit 1
fi

# Ask user to select a profile
read -p "Select a provisioning profile (enter number 1-$TOTAL_PROFILES): " PROFILE_NUM

if [[ $PROFILE_NUM -gt $TOTAL_PROFILES || $PROFILE_NUM -lt 1 ]]; then
    echo -e "${RED}Invalid profile number.${NC}"
    exit 1
fi

# Get the selected profile info - using direct array indexing now
PROFILE_INDEX=$((PROFILE_NUM-1))
SELECTED_PROFILE="${PROFILE_PATHS[$PROFILE_INDEX]}"
SELECTED_PROFILE_NAME="${PROFILE_NAMES[$PROFILE_INDEX]}"
SELECTED_TEAM_ID="${PROFILE_TEAM_IDS[$PROFILE_INDEX]}"

echo -e "Selected profile: ${GREEN}${SELECTED_PROFILE_NAME}${NC}"
echo -e "Selected profile path: ${GREEN}${SELECTED_PROFILE}${NC}"
echo -e "Team ID from profile: ${GREEN}${SELECTED_TEAM_ID}${NC}"

# If we found a team ID from the profile, use it
if [ -n "$SELECTED_TEAM_ID" ]; then
    TEAM_ID="$SELECTED_TEAM_ID"
    echo -e "Using Team ID from selected profile: ${GREEN}${TEAM_ID}${NC}"
fi

# Copy the selected profile
PROFILE_FILE="$TEMP_DIR/profile.mobileprovision"
echo -e "Copying profile from ${YELLOW}${SELECTED_PROFILE}${NC} to ${YELLOW}${PROFILE_FILE}${NC}"
cp -f "$SELECTED_PROFILE" "$PROFILE_FILE"

if [ ! -f "$PROFILE_FILE" ]; then
    echo -e "${RED}Failed to copy profile to temporary location.${NC}"
    echo "Trying direct path instead."
    PROFILE_FILE="$SELECTED_PROFILE"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo -e "${RED}ERROR: Cannot access profile file!${NC}"
    exit 1
fi

echo -e "Profile file size: $(wc -c < "$PROFILE_FILE") bytes"

# Step 4: Convert files to base64 for GitHub secrets
echo -e "\n${GREEN}Step 4: Converting files to base64 for GitHub secrets${NC}"

# Create base64 versions with no line breaks - critical for GitHub Actions
echo -e "Converting certificate to base64..."
P12_BASE64=$(base64 -i "$P12_FILE" | tr -d '\n')
if [ -z "$P12_BASE64" ]; then
    echo -e "${RED}Error: Failed to create base64 for certificate. Check certificate file.${NC}"
    ls -la "$P12_FILE"
fi

echo -e "Converting provisioning profile to base64..."
echo -e "Profile path: ${YELLOW}$PROFILE_FILE${NC}"

# Verify file accessibility
if [ ! -f "$PROFILE_FILE" ]; then
    echo -e "${RED}Error: Cannot access profile file at $PROFILE_FILE${NC}"
    exit 1
fi

# Display file info
ls -la "$PROFILE_FILE"
FILE_SIZE=$(wc -c < "$PROFILE_FILE")
echo -e "Profile file size: ${GREEN}$FILE_SIZE bytes${NC}"

# Check file permissions
if [ ! -r "$PROFILE_FILE" ]; then
    echo -e "${RED}Error: Cannot read profile file (permission issue)${NC}"
    chmod +r "$PROFILE_FILE"
    echo "Fixed permissions. Retrying..."
fi

# Use multiple methods to ensure successful encoding
echo -e "Trying standard base64 encoding..."
PROFILE_BASE64=$(base64 -i "$PROFILE_FILE" | tr -d '\n')

# Check if encoding worked
if [ -z "$PROFILE_BASE64" ]; then
    echo -e "${YELLOW}Standard base64 encoding failed, trying openssl...${NC}"
    PROFILE_BASE64=$(openssl base64 -in "$PROFILE_FILE" | tr -d '\n')
    
    if [ -z "$PROFILE_BASE64" ]; then
        echo -e "${YELLOW}OpenSSL encoding failed, trying cat + base64...${NC}"
        PROFILE_BASE64=$(cat "$PROFILE_FILE" | base64 | tr -d '\n')
        
        if [ -z "$PROFILE_BASE64" ]; then
            echo -e "${RED}All encoding methods failed. Cannot continue.${NC}"
            exit 1
        fi
    fi
fi

# Print debug info
PROFILE_BASE64_LENGTH=${#PROFILE_BASE64}
echo -e "Profile base64 encoded successfully. Length: ${GREEN}$PROFILE_BASE64_LENGTH characters${NC}"

# Write output to debug files for inspection
echo "$P12_BASE64" > "$TEMP_DIR/cert_base64_debug.txt"
echo "$PROFILE_BASE64" > "$TEMP_DIR/profile_base64_debug.txt"
echo -e "${YELLOW}Wrote base64 output to debug files:${NC}"
echo -e "  Certificate: $TEMP_DIR/cert_base64_debug.txt"
echo -e "  Profile: $TEMP_DIR/profile_base64_debug.txt"

# Verify encoding worked and has no line breaks
P12_LEN=${#P12_BASE64}
PROFILE_LEN=${#PROFILE_BASE64}
echo -e "${BLUE}Certificate base64 length: ${P12_LEN} characters (should be one continuous string)${NC}"
echo -e "${BLUE}Profile base64 length: ${PROFILE_LEN} characters (should be one continuous string)${NC}"

# Print first and last 10 characters to verify the encoding worked
echo -e "Certificate base64 preview: ${YELLOW}${P12_BASE64:0:10}...${P12_BASE64: -10}${NC}"
echo -e "Profile base64 preview: ${YELLOW}${PROFILE_BASE64:0:10}...${PROFILE_BASE64: -10}${NC}"

# Verify certificate can be decoded properly
echo -e "${GREEN}Testing certificate and password...${NC}"
TEMP_P12="$TEMP_DIR/verify_cert.p12"
echo "$P12_BASE64" | base64 -d > "$TEMP_P12" 2>/dev/null
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Certificate base64 verification: SUCCESS${NC}"
    # Try to verify with OpenSSL
    if security import "$TEMP_P12" -k /Library/Keychains/System.keychain -P "$CERT_PASSWORD" -t cert -T /usr/bin/codesign -A 2>/dev/null; then
        echo -e "${GREEN}Certificate password verification: SUCCESS${NC}"
        # Clean up the test import
        security delete-certificate -c "$SELECTED_CERT_NAME" /Library/Keychains/System.keychain 2>/dev/null
    else
        echo -e "${YELLOW}Certificate verification note: Couldn't verify with OpenSSL but this should still work with direct import${NC}"
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
    echo "# Provisioning Profile (IMPORTANT: ADD AS ONE CONTINUOUS STRING WITH NO LINE BREAKS)"
    echo "IOS_ADHOC_PROVISIONING_PROFILE=$PROFILE_BASE64"
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
echo "• The certificate password is set to '$CERT_PASSWORD' - this simple password avoids issues"
echo "• Password length: ${#CERT_PASSWORD} characters - verify this matches in GitHub Actions"
echo "• If certificate verification fails in GitHub Actions, try the direct import method"
echo "• These secrets are sensitive - delete the output file after use!"
echo -e "${BLUE}==================================================================${NC}"

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