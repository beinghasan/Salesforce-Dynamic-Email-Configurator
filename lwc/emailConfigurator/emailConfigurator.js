import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { createRecord, updateRecord } from 'lightning/uiRecordApi';
import searchObjects from '@salesforce/apex/ObjectSearchController.searchObjects';
import getObjectFieldsSingleLevel from '@salesforce/apex/ObjectSearchController.getObjectFieldsSingleLevel';
import checkDuplicateTemplate from '@salesforce/apex/ObjectSearchController.checkDuplicateTemplate';
import searchExistingTemplates from '@salesforce/apex/ObjectSearchController.searchExistingTemplates';
import ideaIcon from '@salesforce/resourceUrl/Idea_Icon';

export default class EmailConfigurator extends LightningElement {
    @track objectApiName = '';
    @track templateKey = '';
    @track subject = '';
    @track body = ''; 
    @track availableFields = [];
    @track filteredAvailableFields = [];
    @track fieldSearchInput = '';
    @track objectSearchInput = '';
    @track objectSearchOptions = [];
    @track formRendered = true;
    
    // Lazy-loading breadcrumb navigation stack
    @track pathStack = []; 
    
    activeTab = 'richText';
    searchTimeout;
    childHasDirtyInput = false;
    iconLink = ideaIcon;
    developedBy = 'Mehdi Hasan (mehdi.hasan9b@gmail.com)';

    allowedFormats = [
        'font', 'size', 'bold', 'italic', 'underline', 'strike',
        'list', 'indent', 'align', 'link', 'image', 'clean', 
        'table', 'header', 'color', 'background'
    ];

    // --- NEW CONFIGURATOR STATE TRACKING ---
    @track currentMode = 'new'; // 'new' or 'modify'
    @track templateSearchInput = '';
    @track templateSearchOptions = [];
    @track selectedTemplateId = '';
    @track hasChanges = false;

    // Keep track of pristine base values for modification comparison
    pristineTemplateKey = '';
    pristineObjectApiName = '';
    pristineSubject = '';
    pristineBody = '';

    // Add this right below your @track variables
    get modeOptions() {
        return [
            { label: 'Create New Template', value: 'new' },
            { label: 'Modify Existing', value: 'modify' }
        ];
    }

    get showObjectResults() {
        return this.objectSearchOptions && this.objectSearchOptions.length > 0;
    }

    get showTemplateResults() {
        return this.templateSearchOptions && this.templateSearchOptions.length > 0;
    }

    get currentPathString() {
        if (this.pathStack.length === 0) return 'None Selected';
        return this.pathStack.map(node => node.label).join(' > ');
    }

    get isDrilledDeep() {
        return this.pathStack.length > 1;
    }

    // Dynamic State Control Attributes
    get isNewMode() {
        return this.currentMode === 'new';
    }

    get isModifyMode() {
        return this.currentMode === 'modify';
    }

    get isFormDisabled() {
        // If in Modify mode, disable inputs until an existing template is fully targeted/selected
        return this.isModifyMode && !this.selectedTemplateId;
    }

    get isSaveDisabled() {
        // If modifying an existing layout record, require structural changes before allowing database saves
        if (this.isModifyMode) {
            return !this.selectedTemplateId || !this.hasChanges;
        }
        return false;
    }

    get assistantContainerClass() {
        return this.isFormDisabled ? 'slds-hide' : '';
    }

    // --- MODE TOGGLE LOGIC BLOCK ---
    handleModeChange(event) {
        const selectedValue = event.target.value;
        this.currentMode = selectedValue;
        this.reset();
        
        // Wipe local structural elements cleanly
        this.formRendered = false;
        setTimeout(() => {
            this.formRendered = true;
        }, 0);
    }

    // --- TEMPLATE SEARCH ENGINE METHODS ---
    handleTemplateSearchInput(event) {
        const rawValue = event.detail.value !== undefined ? event.detail.value : event.target.value;
        const searchTerm = rawValue || '';
        this.templateSearchInput = searchTerm;
        const normalizedTerm = searchTerm.trim();

        clearTimeout(this.searchTimeout);

        // If user hits the clear cross button, restore standard disabled state layout maps
        if (!normalizedTerm) {
            this.clearSelectedTemplateData();
            return;
        }

        if (normalizedTerm.length < 3) {
            this.templateSearchOptions = [];
            return;
        }

        this.searchTimeout = setTimeout(() => {
            this.searchTemplatesImperatively(normalizedTerm);
        }, 300);
    }

    async searchTemplatesImperatively(searchTerm) {
        if (!searchTerm) return;
        try {
            const data = await searchExistingTemplates({ searchTerm: searchTerm });
            if (data && Array.isArray(data)) {
                this.templateSearchOptions = data.map(item => {
                    const isSelected = item.value === this.selectedTemplateId;
                    
                    let classes = 'slds-p-around_x-small slds-border_bottom slds-grid slds-grid_align-spread slds-grid_vertical-align-center ';
                    classes += isSelected 
                        ? 'slds-theme_brand-light slds-text-title_bold' 
                        : 'custom-dropdown-item';

                    return {
                        label: item.label || 'Unknown Template',
                        value: item.value || '',
                        sourceObject: item.sourceObject || '',
                        subject: item.subject || '',
                        body: item.body || '',
                        rowClass: classes,
                        isSelected: isSelected
                    };
                });
            } else {
                this.templateSearchOptions = [];
            }
        } catch (error) {
            console.error('Template Search Error:', error);
            this.templateSearchOptions = [];
        }
    }

    async handleTemplateSelect(event) {
        event.preventDefault();
        clearTimeout(this.searchTimeout);

        const targetElement = event.currentTarget || event.target;
        const selectedValue = targetElement ? targetElement.closest('[data-value]')?.dataset.value : null;

        if (!selectedValue) return;

        // Find the matched record layout configurations
        const matchingOption = this.templateSearchOptions.find(opt => opt.value === selectedValue);
        if (!matchingOption) return;

        this.selectedTemplateId = selectedValue;
        this.templateSearchInput = matchingOption.label;
        this.templateSearchOptions = [];

        // Distribute captured metrics safely across data variables
        this.templateKey = matchingOption.label;
        this.objectApiName = matchingOption.sourceObject;
        this.objectSearchInput = matchingOption.sourceObject;
        this.subject = matchingOption.subject;
        this.body = matchingOption.body;

        // Save reference configurations for tracking field updates dynamically
        this.pristineTemplateKey = this.templateKey;
        this.pristineObjectApiName = this.objectApiName;
        this.pristineSubject = this.subject;
        this.pristineBody = this.body;
        this.hasChanges = false;

        // Reset and fetch related contextual token path properties
        this.pathStack = [{
            object: this.objectApiName,
            relName: '',
            label: this.objectApiName
        }];

        await this.loadFieldsForCurrentStackLevel();
    }

    handleTemplateInputClick(event) {
        const currentInput = event.target.value || '';
        const normalizedTerm = currentInput.trim();
        if (normalizedTerm && normalizedTerm.length >= 3) {
            this.searchTemplatesImperatively(normalizedTerm);
        }
    }

    handleTemplateInputBlur() {
        // Safe interactive transition delay
        setTimeout(() => {
            this.templateSearchOptions = [];
        }, 200);
    }

    clearSelectedTemplateData() {
        this.selectedTemplateId = '';
        this.templateKey = '';
        this.objectApiName = '';
        this.objectSearchInput = '';
        this.subject = '';
        this.body = '';
        this.hasChanges = false;
        this.templateSearchOptions = [];
        this.clearAndHideAllPlaceholders();
    }

    // Check if the current modification changes differ from base metrics
    evaluateChangeStatus() {
        if (this.isNewMode) return;
        this.hasChanges = (
            this.templateKey !== this.pristineTemplateKey ||
            this.objectApiName !== this.pristineObjectApiName ||
            this.subject !== this.pristineSubject ||
            this.body !== this.pristineBody
        );
    }

    // --- OBJECT SEARCH ENGINE METHODS ---
    handleObjectSearchInput(event) {
        const rawValue = event.detail.value !== undefined ? event.detail.value : event.target.value;
        const searchTerm = rawValue || '';
        this.objectSearchInput = searchTerm;
        const normalizedTerm = searchTerm.trim();

        clearTimeout(this.searchTimeout);

        if (!normalizedTerm) {
            this.clearAndHideAllPlaceholders();
            this.evaluateChangeStatus();
            return;
        }

        if (normalizedTerm.length < 3) {
            this.objectSearchOptions = [];
            return;
        }

        this.searchTimeout = setTimeout(() => {
            this.searchObjectsImperatively(normalizedTerm);
        }, 300);
    }

    async searchObjectsImperatively(searchTerm) {
        if (!searchTerm) return;
        try {
            const data = await searchObjects({ searchTerm: searchTerm });
            if (data && Array.isArray(data)) {
                this.objectSearchOptions = data.map(item => {
                    const isSelected = item.value === this.objectApiName;
                    
                    let classes = 'slds-p-around_x-small slds-border_bottom slds-grid slds-grid_align-spread slds-grid_vertical-align-center ';
                    classes += isSelected 
                        ? 'slds-theme_brand-light slds-text-title_bold' 
                        : 'custom-dropdown-item';

                    return {
                        label: item.label || 'Unknown Object',
                        value: item.value || '',
                        rowClass: classes,
                        isSelected: isSelected
                    };
                });
            } else {
                this.objectSearchOptions = [];
            }
        } catch (error) {
            console.error('Search Error:', error);
            this.objectSearchOptions = [];
        }
    }

    async handleObjectSelect(event) {
        event.preventDefault(); 
        clearTimeout(this.searchTimeout);
        
        const targetElement = event.currentTarget || event.target;
        const selectedValue = targetElement ? targetElement.closest('[data-value]')?.dataset.value : null;
        
        if (!selectedValue) return;

        this.objectApiName = selectedValue;
        this.objectSearchInput = selectedValue; 
        this.objectSearchOptions = []; 
        this.fieldSearchInput = '';

        this.pathStack = [{
            object: selectedValue,
            relName: '', 
            label: selectedValue
        }];

        await this.loadFieldsForCurrentStackLevel();
        this.evaluateChangeStatus();
    }

    handleObjectInputClick(event) {
        if (this.isFormDisabled) return;
        const currentInput = event.target.value || '';
        const normalizedTerm = currentInput.trim();

        if (normalizedTerm && normalizedTerm.length >= 3) {
            this.searchObjectsImperatively(normalizedTerm);
        }
    }

    handleObjectInputBlur() {
        setTimeout(() => {
            this.objectSearchOptions = [];
        }, 200);
    }

    async loadFieldsForCurrentStackLevel() {
        if (this.pathStack.length === 0) return;
        const currentLevel = this.pathStack[this.pathStack.length - 1];

        try {
            const rawFields = await getObjectFieldsSingleLevel({ objectApiName: currentLevel.object });
            
            if (rawFields && rawFields.length > 0) {
                let tokenPrefix = '';
                this.pathStack.forEach((node, index) => {
                    if (index > 0 && node.relName) {
                        if (node.relName.toLowerCase() === 'related') {
                            return;
                        }
                        tokenPrefix += node.relName + '.';
                    }
                });

                const formattedFields = rawFields.map(field => {
                    const finalToken = field.isLookup 
                        ? `[[${tokenPrefix}${field.relationshipName}.Name]]` 
                        : `[[${tokenPrefix}${field.name}]]`;

                    return {
                        ...field,
                        finalToken: finalToken,
                        uiDisplayLabel: field.isLookup ? `${field.label} >` : field.label
                    };
                });

                formattedFields.sort((a, b) => a.uiDisplayLabel.localeCompare(b.uiDisplayLabel));

                this.availableFields = [...formattedFields];
                this.filteredAvailableFields = [...formattedFields];
            } else {
                this.showNoFieldsToast(currentLevel.object);
            }
        } catch (error) {
            console.error('LWC Drill-down Communication Error:', error);
            this.showNoFieldsToast(currentLevel.object);
        }
    }

    async handleDrillDown(event) {
        event.stopPropagation(); 
        if (this.isFormDisabled) return;
        if (this.pathStack.length >= 5) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Traversal Limit',
                message: 'Salesforce limits relationship merge tokens to 5 levels.',
                variant: 'warning'
            }));
            return;
        }

        const targetObject = event.currentTarget.dataset.targetobject;
        const relName = event.currentTarget.dataset.relname;         
        const label = event.currentTarget.dataset.label;             

        this.pathStack.push({ 
            object: targetObject, 
            relName: relName, 
            label: label 
        });
        
        this.fieldSearchInput = '';
        await this.loadFieldsForCurrentStackLevel();
    }

    async handleNavigateBack() {
        if (this.isFormDisabled) return;
        if (this.pathStack.length > 1) {
            this.pathStack.pop();
            this.fieldSearchInput = '';
            await this.loadFieldsForCurrentStackLevel();
        }
    }

    handleFieldClick(event) {
        if (this.isFormDisabled) return;
        const isLookup = event.currentTarget.dataset.islookup === 'true';
        if (isLookup) return; 

        const selectedToken = event.currentTarget.dataset.token;
        if (!selectedToken) return;

        navigator.clipboard.writeText(selectedToken);
        this.dispatchEvent(new ShowToastEvent({
            title: 'Copied Token!',
            message: `${selectedToken} successfully copied.`,
            variant: 'info'
        }));
    }

    handleFieldSearchChange(event) {
        const inputValue = event.target.value || '';
        this.fieldSearchInput = inputValue;
        const searchTerm = inputValue.toLowerCase();

        if (!searchTerm) {
            this.filteredAvailableFields = this.availableFields;
            return;
        }
        
        this.filteredAvailableFields = this.availableFields.filter(field => 
            (field.label && field.label.toLowerCase().includes(searchTerm)) || 
            (field.name && field.name.toLowerCase().includes(searchTerm))
        );
    }

    showNoFieldsToast(objName) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'No Fields Available',
            message: `Could not retrieve field metadata layout maps for: "${objName}".`,
            variant: 'info'
        }));
    }
    
    handleKeyChange(event) { 
        this.templateKey = event.target.value; 
        this.evaluateChangeStatus();
    }
    
    handleSubjectChange(event) { 
        this.subject = event.target.value; 
        this.evaluateChangeStatus();
    }
    
    handleBodyChange(event) { 
        this.body = event.target.value; 
        this.evaluateChangeStatus();
    }
    
    handleTabChange(event) { this.activeTab = event.target.value; }
    handlePreviewActive() {} 

    handleTokenClick(event) {
        this.handleFieldClick(event);
    }

    async saveTemplate() {
        // ... (Keep your existing validation checks exactly the same) ...

        // Bundle metrics structured cleanly for database operation
        const fields = {
            'Name': this.templateKey,
            'Source_Object__c': this.objectApiName,
            'Subject__c': this.subject,
            'Body__c': this.body
        };

        // If modifying an existing template, inject the record reference token targeting parameter
        if (this.isModifyMode && this.selectedTemplateId) {
            fields['Id'] = this.selectedTemplateId;
        }

        try {
            // Only enforce duplicate checks when creating brand-new layout patterns
            if (this.isNewMode) {
                try {
                    const isDuplicate = await checkDuplicateTemplate({ 
                        templateName: this.templateKey, 
                        subjectLine: this.subject 
                    });

                    if (isDuplicate) {
                        this.showValidationError(
                            'Template Already Exists', 
                            'An email template with this exact configuration name or subject line already exists.'
                        );
                        return; // Halt save execution completely
                    }
                } catch (error) {
                    console.error('Duplicate Check Error:', error);
                }
            }

            if (this.isModifyMode) {
                // Directly call the statically imported method now
                await updateRecord({ fields });
            } else {
                await createRecord({ apiName: 'Dynamic_Email_Template__c', fields });
            }

            this.dispatchEvent(new ShowToastEvent({
                title: 'Success',
                message: this.isModifyMode ? 'Template configuration updated successfully.' : 'Template configuration saved successfully.',
                variant: 'success'
            }));

            // Refresh pristine records post layout modifications
            if (this.isModifyMode) {
                this.pristineTemplateKey = this.templateKey;
                this.pristineObjectApiName = this.objectApiName;
                this.pristineSubject = this.subject;
                this.pristineBody = this.body;
                this.hasChanges = false;
            } else {
                this.handleCancel();
            }
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error Saving Configuration',
                message: error?.body?.message || 'An unexpected database mapping error occurred.',
                variant: 'error'
            }));
        }
    }

    helperMethodToKeepToastDispatchesClean(title, message) {
        this.showValidationError(title, message);
    }

    showValidationError(title, message) {
        this.dispatchEvent(new ShowToastEvent({
            title: title,
            message: message,
            variant: 'error'
        }));
    }

    handleChildInputChange() {
        this.childHasDirtyInput = true;
    }

    handleCancel() {
        // Look directly at our clean tracking state variable
        const hasDataToClear = 
            this.templateKey || 
            this.objectApiName || 
            this.subject || 
            this.body || 
            this.templateSearchInput || 
            this.selectedTemplateId || 
            this.availableFields.length > 0 || 
            this.childHasDirtyInput; // No DOM querying, 100% safe from Aura script errors

        // Run the state reset engine
        this.reset();

        // Drop and recreate the form fields to wipe native component configurations
        this.formRendered = false;
        setTimeout(() => {
            this.formRendered = true;
        }, 0);
        
        // ONLY dispatch the visual toast notice if there was structural content to clear
        if (hasDataToClear) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Form Reset',
                message: 'All values, templates targets, and loaded token states have been completely cleared.',
                variant: 'info'
            }));
        }
    }

    reset() {
        this.objectApiName = '';
        this.objectSearchInput = ''; 
        this.templateKey = '';       
        this.subject = '';           
        this.body = '';              
        this.templateSearchInput = '';
        this.selectedTemplateId = '';
        this.hasChanges = false;
        this.objectSearchOptions = [];
        this.templateSearchOptions = [];
        this.availableFields = [];
        this.filteredAvailableFields = [];
        this.fieldSearchInput = '';
        this.pathStack = [];
        this.activeTab = 'richText'; 
        this.childHasDirtyInput = false;
    }

    clearAndHideAllPlaceholders() {
        this.objectApiName = '';
        this.objectSearchOptions = [];
        this.availableFields = [];
        this.filteredAvailableFields = [];
        this.fieldSearchInput = '';
        this.pathStack = [];
    }

    handleAiDraftGenerated(event) {
        if (this.isFormDisabled) return;
        this.subject = event.detail.subject;
        this.body = event.detail.body;
        this.evaluateChangeStatus();
    }
}