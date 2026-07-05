public with sharing class ObjectSearchController {
    public class ObjectOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
    }
    
    public class FieldWrapper {
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String type { get; set; }
        @AuraEnabled public Boolean isLookup { get; set; }
        @AuraEnabled public String referenceTo { get; set; } // e.g., "Account"
        @AuraEnabled public String relationshipName { get; set; } // e.g., "Account"
    }

    @AuraEnabled
    public static List<FieldWrapper> getObjectFieldsSingleLevel(String objectApiName) {
        List<FieldWrapper> results = new List<FieldWrapper>();
        if (String.isBlank(objectApiName)) return results;

        try {
            Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
            String exactApiName = objectApiName;
            
            // Case-insensitive matching
            for (String key : globalDescribe.keySet()) {
                if (key.equalsIgnoreCase(objectApiName.trim())) {
                    exactApiName = key;
                    break;
                }
            }

            if (!globalDescribe.containsKey(exactApiName)) return results;

            Schema.DescribeSObjectResult objDescribe = globalDescribe.get(exactApiName).getDescribe();
            Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();

            for (Schema.SObjectField fieldToken : fieldMap.values()) {
                try {
                    Schema.DescribeFieldResult fieldDescribe = fieldToken.getDescribe();
                    
                    // Skip inaccessible fields early to keep processing efficient
                    if (!fieldDescribe.isAccessible()) continue;

                    String fieldName = fieldDescribe.getName();

                    // === CRITICAL FILTER FOR QUEUE (GROUP) METADATA ===
                    if (exactApiName.equalsIgnoreCase('Group')) {
                        // 1. Skip RelatedId and OwnerId to remove the system lookup loops
                        if (fieldName.equalsIgnoreCase('RelatedId') || 
                            fieldName.equalsIgnoreCase('OwnerId')) {
                            continue;
                        }
                        
                        // 2. Map the standard 'Id' field to display explicitly as 'Queue ID'
                        if (fieldName.equalsIgnoreCase('Id')) {
                            FieldWrapper qIdWrapper = new FieldWrapper();
                            qIdWrapper.name = 'Id';
                            qIdWrapper.label = 'Queue ID';
                            qIdWrapper.type = 'ID';
                            qIdWrapper.isLookup = false;
                            results.add(qIdWrapper);
                            continue;
                        }
                    }

                    FieldWrapper wrapper = new FieldWrapper();
                    wrapper.name = fieldDescribe.getName();
                    wrapper.label = fieldDescribe.getLabel();
                    wrapper.type = fieldDescribe.getType().name();
                    wrapper.isLookup = false;

                    String relName = fieldDescribe.getRelationshipName();
                    if (String.isNotBlank(relName)) {
                        List<Schema.SObjectType> targets = fieldDescribe.getReferenceTo();
                        
                        if (targets != null && !targets.isEmpty()) {
                            
                            // --- POLYMORPHIC FIELDS INTERCEPT BLOCK (e.g., OwnerId) ---
                            if (targets.size() > 1) {
                                for (Schema.SObjectType refType : targets) {
                                    String targetObjectName = refType.getDescribe().getName(); // 'User' or 'Group'
                                    
                                    FieldWrapper polyWrapper = new FieldWrapper();
                                    polyWrapper.name = wrapper.name;
                                    polyWrapper.type = wrapper.type;
                                    polyWrapper.isLookup = true;
                                    polyWrapper.referenceTo = targetObjectName;
                                    
                                    // Format the label exactly to match standard Salesforce UI split
                                    String typeLabel = (targetObjectName == 'Group') ? 'Queue' : targetObjectName;
                                    polyWrapper.label = wrapper.label + ' (' + typeLabel + ')';
                                    polyWrapper.relationshipName = relName; // 'Owner'
                                    
                                    results.add(polyWrapper);
                                }
                                continue; // Skip standard wrapper addition since splits are handled
                            }
                            
                            // --- STANDARD SINGULAR LOOKUP BLOCK ---
                            wrapper.isLookup = true;
                            wrapper.referenceTo = targets[0].getDescribe().getName();
                            wrapper.relationshipName = relName;
                        }
                    }
                    
                    results.add(wrapper);
                } catch (Exception e) {
                    continue; // Skip restricted fields safely
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }

        return results;
    }

    @AuraEnabled (cacheable=true)
    public static List<ObjectOption> searchObjects(String searchTerm) {
        List<ObjectOption> options = new List<ObjectOption>();

        if (String.isBlank(searchTerm)) {
            return options;
        }

        String normalizedTerm = searchTerm.trim().toLowerCase();
        if (normalizedTerm.length() < 3) {
            return options;
        }

        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        
        // Loop through all objects to get their labels
        for (String apiName : globalDescribe.keySet()) {
            Schema.DescribeSObjectResult describeResult = globalDescribe.get(apiName).getDescribe();
            
            // STRICT FILTER: Must be queryable, accessible, layoutable, and NOT a background system bridge table
            if (describeResult.isAccessible() && 
                describeResult.isQueryable() && 
                describeResult.isCreateable() && // Screens out system read-only data logs
                !apiName.endsWithIgnoreCase('history') && 
                !apiName.endsWithIgnoreCase('share') && 
                !apiName.endsWithIgnoreCase('feed') && 
                !apiName.endsWithIgnoreCase('__e')) {
                
                String label = describeResult.getLabel();
                String normalizedLabel = String.isBlank(label) ? '' : label.toLowerCase();
                String normalizedApiName = apiName.toLowerCase();
        
                if (normalizedLabel.contains(normalizedTerm) || normalizedApiName.contains(normalizedTerm)) {
                    ObjectOption option = new ObjectOption();
                    option.label = label + ' (' + apiName + ')';
                    option.value = apiName;
                    options.add(option);
                }
            }
        
            if (options.size() >= 50) { break; }
        }
        
        System.debug('Matching options found --> Size: ' + options.size()+' & options: '+options);
        return options;
    }
    

    @AuraEnabled
    public static List<String> getObjectFields(String objectApiName) {
        List<String> tokens = new List<String>();
        if (String.isBlank(objectApiName)) {
            return tokens;
        }

        try {
            Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
            Schema.SObjectType targetType = globalDescribe.get(objectApiName);
            
            if (targetType == null) {
                // Fallback case check
                for (String key : globalDescribe.keySet()) {
                    if (key.equalsIgnoreCase(objectApiName.trim())) {
                        targetType = globalDescribe.get(key);
                        break;
                    }
                }
            }

            if (targetType != null) {
                // Kick off the recursion starting at Level 1, with an empty prefix path
                generateTokensRecursively(targetType, '', 1, tokens);
            }
        } catch (Exception e) {
            System.debug('Error generating deep tokens: ' + e.getMessage());
            AuraHandledException auraEx = new AuraHandledException(e.getMessage());
            auraEx.setMessage(e.getMessage());
            throw auraEx;
        }

        tokens.sort();
        return tokens;
    }

    /**
     * Recursive helper to discover relationships up to 5 levels deep
     */
    private static void generateTokensRecursively(
        Schema.SObjectType currentObjectType, 
        String pathPrefix, 
        Integer currentLevel, 
        List<String> tokens
    ) {
        // Base Guard: Maximum depth allowed by Salesforce standard relationships is 5
        if (currentLevel > 3 || currentObjectType == null) {
            return;
        }

        Schema.DescribeSObjectResult objDescribe = currentObjectType.getDescribe();
        Map<String, Schema.SObjectField> fieldMap = objDescribe.fields.getMap();

        for (Schema.SObjectField fieldToken : fieldMap.values()) {
            try {
                Schema.DescribeFieldResult fieldDescribe = fieldToken.getDescribe();
                String fieldName = fieldDescribe.getName();
                String relName = fieldDescribe.getRelationshipName();

                // 1. Generate token for the current primitive field
                tokens.add('[[' + pathPrefix + fieldName + ']]');

                // 2. If it's a lookup/master-detail relationship, traverse deeper
                if (String.isNotBlank(relName)) {
                    // Generate basic related name token (e.g., Account.Name or Contact.Account.Name)
                    tokens.add('[[' + pathPrefix + relName + '.Name]]');

                    // Special handling for User/Owner emails
                    if (fieldName.equalsIgnoreCase('OwnerId') || fieldName.toLowerCase().contains('user')) {
                        tokens.add('[[' + pathPrefix + relName + '.Email]]');
                    }

                    // Extract the destination object type for the next recursive jump
                    List<Schema.SObjectType> referenceToTargets = fieldDescribe.getReferenceTo();
                    if (referenceToTargets != null && !referenceToTargets.isEmpty()) {
                        // Use the first target type (handles standard lookups smoothly)
                        Schema.SObjectType nextObjectType = referenceToTargets[0];
                        
                        // Formulate the path prefix for the next depth level (e.g., "Account.")
                        String nextPrefix = pathPrefix + relName + '.';

                        // Recursively move to the next level
                        generateTokensRecursively(nextObjectType, nextPrefix, currentLevel + 1, tokens);
                    }
                }
            } catch (Exception fieldEx) {
                // Skip un-describable system or compound fields quietly
                continue;
            }
        }
    }

    @AuraEnabled(cacheable=false)
    public static Boolean checkDuplicateTemplate(String templateName, String subjectLine) {
        // Queries the database to see if a record already matches either unique criteria
        List<Dynamic_Email_Template__c> duplicates = [
            SELECT Id 
            FROM Dynamic_Email_Template__c 
            WHERE Name = :templateName OR Subject__c = :subjectLine
            LIMIT 1
        ];
        
        // Returns true if a match is found, false if the path is clear
        return !duplicates.isEmpty();
    }

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> searchExistingTemplates(String searchTerm) {
        List<Map<String, String>> options = new List<Map<String, String>>();
        if (String.isBlank(searchTerm)) return options;
        
        String likeQuery = '%' + searchTerm + '%';
        List<Dynamic_Email_Template__c> templates = [
            SELECT Id, Name, Source_Object__c, Subject__c, Body__c 
            FROM Dynamic_Email_Template__c 
            WHERE Name LIKE :likeQuery 
            LIMIT 10
        ];
        
        for (Dynamic_Email_Template__c t : templates) {
            Map<String, String> item = new Map<String, String>();
            item.put('label', t.Name);
            item.put('value', t.Id);
            item.put('sourceObject', t.Source_Object__c);
            item.put('subject', t.Subject__c);
            item.put('body', t.Body__c);
            options.add(item);
        }
        return options;
    }
}