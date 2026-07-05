public with sharing class DynamicEmailEngine {

    public class EmailRequest {
        @InvocableVariable(required=true label='Template Key Name') 
        public String templateKey;
        
        @InvocableVariable(required=true label='Target Record ID') 
        public Id recordId;
        
        @InvocableVariable(required=true label='Recipient Email Addresses') 
        public List<String> recipientEmails;
    }

    @InvocableMethod(label='Send Dynamic Email' description='Parses deep-relationship placeholders and fires custom email.')
    public static void sendDynamicEmailFlow(List<EmailRequest> requests) {
        for(EmailRequest req : requests) {
            sendEmail(req.templateKey, req.recordId, req.recipientEmails);
        }
    }

    public static void sendEmail(String templateName, Id recordId, List<String> recipientEmails) {
        List<Dynamic_Email_Template__c> templates = [
            SELECT Subject__c, Body__c, Source_Object__c 
            FROM Dynamic_Email_Template__c 
            WHERE Name = :templateName 
            LIMIT 1
        ];
        
        if (templates.isEmpty()) {
            System.debug('❌ DynamicEmailEngine Error: No email template found with Name: ' + templateName);
            return;
        }
        
        Dynamic_Email_Template__c template = templates[0];
        String bodyText = template.Body__c;
        String subjectText = template.Subject__c;

        Set<String> tokensFound = extractTokens(bodyText + ' ' + subjectText); 
        
        Set<String> soqlFields = new Set<String>{'Id'};
        Boolean needsOwnerDetails = false;

        for(String token : tokensFound) {
            if(token == 'RecordLink') {
                continue;
            }
            
            // CRITICAL STRIP: If the token attempts to dot-walk through Owner on a Case, 
            // skip adding it to the main query to prevent the relationship crash.
            if(template.Source_Object__c.equalsIgnoreCase('Case') && token.startsWithIgnoreCase('Owner.')) {
                needsOwnerDetails = true;
                // We must query OwnerId to fetch the details later
                soqlFields.add('OwnerId'); 
                continue;
            }
            
            soqlFields.add(token);
        }

        // Execute the main dynamic query safely without illegal relationship paths
        String objectApiName = template.Source_Object__c;
        String queryString = 'SELECT ' + String.join(new List<String>(soqlFields), ', ') + ' FROM ' + objectApiName + ' WHERE Id = :recordId LIMIT 1';
        SObject dataRecord = Database.query(queryString);

        // SECONDARY RECOVERY MAP: If polymorphic owner tokens were requested, resolve them cleanly
        Map<String, String> polymorphicFallbackMap = new Map<String, String>();
        if(needsOwnerDetails && dataRecord != null && dataRecord.get('OwnerId') != null) {
            Id ownerId = (Id)dataRecord.get('OwnerId');
            
            // Only process if the owner is a User (Queues start with '00G')
            if(ownerId.getSObjectType() == User.SObjectType) {
                List<User> ownerUsers = [SELECT Email, Manager.Email, Manager.Name FROM User WHERE Id = :ownerId LIMIT 1];
                if(!ownerUsers.isEmpty()) {
                    User u = ownerUsers[0];
                    polymorphicFallbackMap.put('Owner.Email', u.Email);
                    polymorphicFallbackMap.put('Owner.Manager.Email', u.Manager?.Email);
                    polymorphicFallbackMap.put('Owner.Manager.Name', u.Manager?.Name);
                }
            }
        }

        String sfBaseUrl = URL.getOrgDomainUrl().toExternalForm();
        String dynamicRecordLink = sfBaseUrl + '/' + recordId;

        // Merge tokens
        for(String token : tokensFound) {
            String replacePlaceholder = '[[' + token + ']]';
            
            if(token == 'RecordLink') {
                bodyText = bodyText.replace(replacePlaceholder, dynamicRecordLink);
                subjectText = subjectText.replace(replacePlaceholder, dynamicRecordLink);
            } else if(polymorphicFallbackMap.containsKey(token)) {
                // Use the safely fetched secondary user details map
                String value = polymorphicFallbackMap.get(token);
                bodyText = bodyText.replace(replacePlaceholder, value != null ? value : '');
                subjectText = subjectText.replace(replacePlaceholder, value != null ? value : '');
            } else {
                // Standard database extraction path
                String dbValue = getFieldValue(dataRecord, token); 
                bodyText = bodyText.replace(replacePlaceholder, dbValue != null ? dbValue : '');
                subjectText = subjectText.replace(replacePlaceholder, dbValue != null ? dbValue : '');
            }
        }

        // Rest of your messaging delivery logic remains untouched...
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        List<String> resolvedRecipients = new List<String>();
        if (recipientEmails != null) {
            for (String address : recipientEmails) {
                if (String.isNotBlank(address)) resolvedRecipients.add(address.trim());
            }
        }
        if (resolvedRecipients.isEmpty()) {
            String fallbackEmail = UserInfo.getUserEmail();
            if (String.isNotBlank(fallbackEmail)) resolvedRecipients.add(fallbackEmail);
        }

        OrgWideEmailAddress[] owea = [SELECT Id FROM OrgWideEmailAddress WHERE Address = 'mehdi.hasan9b@gmail.com'];
        if (owea.size() > 0) mail.setOrgWideEmailAddressId(owea[0].Id);
        
        mail.setToAddresses(resolvedRecipients);
        mail.setSubject(subjectText);
        mail.setHtmlBody(bodyText);
        mail.setTreatTargetObjectAsRecipient(false);
        mail.setSaveAsActivity(false);

        try {
            Messaging.sendEmail(new Messaging.SingleEmailMessage[] { mail });
            System.debug('✅ DynamicEmailEngine: Email send request submitted successfully.');
        } catch (EmailException e) {
            System.debug('❌ DynamicEmailEngine EmailException: ' + e.getMessage());
            throw e;
        }
    }

    private static String getFieldValue(sObject record, String fieldPath) {
        if (record == null) return '';
        if (!fieldPath.contains('.')) {
            try {
                return record.get(fieldPath) != null ? String.valueOf(record.get(fieldPath)) : '';
            } catch(Exception e) {
                return '';
            }
        }
        String nextRelation = fieldPath.substringBefore('.');
        String remainingPath = fieldPath.substringAfter('.');
        try {
            sObject parentRecord = record.getSObject(nextRelation);
            return getFieldValue(parentRecord, remainingPath);
        } catch (Exception e) {
            return ''; 
        }
    }

    public static Set<String> extractTokens(String sourceText) {
        Set<String> tokens = new Set<String>();
        if (String.isBlank(sourceText)) return tokens;
        Pattern tokenPattern = Pattern.compile('\\[\\[(.*?)\\]\\]');
        Matcher tokenMatcher = tokenPattern.matcher(sourceText);
        while (tokenMatcher.find()) {
            String token = tokenMatcher.group(1);
            if (String.isNotBlank(token)) tokens.add(token.trim());
        }
        return tokens;
    }
}