import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import generateEmailDraft from '@salesforce/apex/AgentforceEmailService.generateEmailDraft';

export default class AgentforceEmailAssistant extends LightningElement {
    @api selectedObjectApiName; // Passed down from parent component
    @api isDisabled = false; // Expose public property to catch parent state changes
    
    @track aiPromptInput = '';
    @track isAiLoading = false;

    // Combine internal loading rules with parent lock down signals
    get isAiComponentDisabled() {
        return this.isDisabled || this.isAiLoading;
    }

    handleAiPromptChange(event) {
        this.aiPromptInput = event.target.value;
    }

    async executeAiDrafting() {
        if (!this.selectedObjectApiName) {
            this.showToast('Target Object Required', 'Please pick an active object schema on the left first so the AI can orient its context parameters.', 'warning');
            return;
        }

        if (!this.aiPromptInput.trim()) {
            this.showToast('Instructions Missing', 'Please tell Agentforce what kind of email draft template you want generated.', 'warning');
            return;
        }

        this.isAiLoading = true;

        try {
            const aiResult = await generateEmailDraft({
                objectName: this.selectedObjectApiName,
                instructions: this.aiPromptInput
            });

            if (aiResult) {
                // Dispatch event containing data back up to the parent component
                const selectEvent = new CustomEvent('draftgenerate', {
                    detail: {
                        subject: aiResult.subject || '',
                        body: aiResult.body || ''
                    }
                });
                this.dispatchEvent(selectEvent);
                
                this.showToast('Draft Generated', 'Agentforce successfully populated your template values.', 'success');
            }
        } catch (error) {
            console.error('Agentforce Orchestration Error: ', error);
            this.showToast('AI Generation Failed', error?.body?.message || 'An error occurred while communicating with the Einstein trust layer.', 'error');
        } finally {
            this.isAiLoading = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}