public with sharing class AgentforceEmailService {

    public class AIResponse {
        @AuraEnabled public String subject { get; set; }
        @AuraEnabled public String body { get; set; }
    }

    @AuraEnabled
    public static AIResponse generateEmailDraft(String objectName, String instructions) {
        AIResponse responseWrapper = new AIResponse();
        
        String corePrompt = 'You are an advanced enterprise communication AI. Draft an email based on the following context.\n'
            + 'Target Object Type: ' + objectName + '\n'
            + 'User Instructions/Goals: ' + instructions + '\n\n'
            + 'CRITICAL OUTPUT INSTRUCTIONS:\n'
            + 'Provide your response strictly split by these token markers so it can be cleanly parsed:\n'
            + '===SUBJECT===\n[Insert Your Subject Line Here]\n'
            + '===BODY===\n[Insert Your HTML/Rich Text Email Body Here]';

        try {
            // 1. Initialize the root generation request
            aiplatform.ModelsAPI.createGenerations_Request request = new aiplatform.ModelsAPI.createGenerations_Request();
            // Feel free to update to 'sfdc_ai__DefaultOpenAIGPT4OmniMini' if preferred for speed
            request.modelName = 'sfdc_ai__DefaultOpenAIGPT4Omni'; 

            // FIX: Changed from plural 'GenerationsRequest' to singular 'GenerationRequest'
            aiplatform.ModelsAPI_GenerationRequest bodyPayload = new aiplatform.ModelsAPI_GenerationRequest();
            bodyPayload.prompt = corePrompt;
            request.body = bodyPayload;

            // 2. Instantiate the ModelsAPI engine class execution context
            aiplatform.ModelsAPI modelsAPIInstance = new aiplatform.ModelsAPI();
            aiplatform.ModelsAPI.createGenerations_Response apiResponse = modelsAPIInstance.createGenerations(request);
            
            // 3. FIX: Safely parse text from the verified node mapping path (.Code200.generation.generatedText)
            String rawAiText = '';
            if (apiResponse != null && apiResponse.Code200 != null && apiResponse.Code200.generation != null) {
                rawAiText = apiResponse.Code200.generation.generatedText;
            }

            // 4. Parse out the Subject and Body fragments using our token headers
            if (String.isNotBlank(rawAiText)) {
                if (rawAiText.contains('===SUBJECT===') && rawAiText.contains('===BODY===')) {
                    responseWrapper.subject = rawAiText.substringBetween('===SUBJECT===', '===BODY===').trim();
                    responseWrapper.body = rawAiText.substringAfter('===BODY===').trim();
                } else {
                    responseWrapper.subject = 'Suggested Draft for ' + objectName;
                    responseWrapper.body = rawAiText;
                }
            }
        } catch (aiplatform.ModelsAPI.createGenerations_ResponseException e) {
            System.debug('Einstein Trust Layer API Exception Status Code: ' + e.responseCode);
            throw new AuraHandledException('Einstein Trust Layer API Exception: ' + e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('General Agentforce Service Error: ' + e.getMessage());
        }

        return responseWrapper;
    }
}