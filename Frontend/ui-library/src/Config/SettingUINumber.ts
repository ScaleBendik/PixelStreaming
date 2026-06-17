// Copyright Epic Games, Inc. All Rights Reserved.

import type { NumericParametersIds, SettingNumber } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.7';
import { Logger, NumericParameters } from '@epicgames-ps/lib-pixelstreamingfrontend-ue5.7';
import { SettingUIBase } from './SettingUIBase';

type DurationFields = {
    hours: HTMLInputElement;
    minutes: HTMLInputElement;
    seconds: HTMLInputElement;
};

/**
 * A number spinner with a text label beside it.
 */
export class SettingUINumber<CustomIds extends string = NumericParametersIds> extends SettingUIBase {
    _spinner: HTMLInputElement;
    _durationInputRow: HTMLElement;
    _durationFields: DurationFields;

    /* This element contains a text node that reflects the setting's text label. */
    _settingsTextElem: HTMLElement;

    constructor(setting: SettingNumber<CustomIds>) {
        super(setting);

        this.label = this.setting.label;
        this.number = this.setting.number;
    }

    /**
     * @returns The setting component.
     */
    public override get setting(): SettingNumber<CustomIds> {
        return this._setting as SettingNumber<CustomIds>;
    }

    private get isAfkTimeoutSetting(): boolean {
        return this.setting.id === NumericParameters.AFKTimeoutSecs;
    }

    public get settingsTextElem(): HTMLElement {
        if (!this._settingsTextElem) {
            this._settingsTextElem = document.createElement('label');
            this._settingsTextElem.innerText = this.setting.label;
            this._settingsTextElem.title = this.setting.description;
        }
        return this._settingsTextElem;
    }

    /**
     * Get the HTMLInputElement for the button.
     */
    public get spinner(): HTMLInputElement {
        if (!this._spinner) {
            this._spinner = document.createElement('input');
            this._spinner.type = 'number';
            if (this.setting.min != null) {
                this._spinner.min = this.setting.min.toString();
            }
            if (this.setting.max != null) {
                this._spinner.max = this.setting.max.toString();
            }
            this._spinner.value = this.setting.number.toString();
            this._spinner.title = this.setting.description;
            this._spinner.classList.add('form-control');

            // Block keypress/up/down propogation from text field typing going to UE
            this.spinner.addEventListener('keypress', (event) => {
                event.stopPropagation();
            });
            this.spinner.addEventListener('keyup', (event) => {
                event.stopPropagation();
            });
            this.spinner.addEventListener('keydown', (event) => {
                event.stopPropagation();
            });
        }
        return this._spinner;
    }

    private createDurationField(label: string, max?: number): HTMLInputElement {
        const input = document.createElement('input');
        input.type = 'number';
        input.min = '0';
        input.step = '1';
        input.inputMode = 'numeric';
        if (max != null) {
            input.max = max.toString();
        }
        input.title = `${this.setting.description} (${label})`;
        input.classList.add('form-control');
        input.classList.add('duration-control-input');

        // Block keypress/up/down propogation from text field typing going to UE
        input.addEventListener('keypress', (event) => {
            event.stopPropagation();
        });
        input.addEventListener('keyup', (event) => {
            event.stopPropagation();
        });
        input.addEventListener('keydown', (event) => {
            event.stopPropagation();
        });
        input.addEventListener('change', () => {
            this.commitDurationFields();
        });

        return input;
    }

    private createDurationFieldGroup(label: string, input: HTMLInputElement): HTMLElement {
        const group = document.createElement('span');
        group.classList.add('duration-control-field');

        const unitLabel = document.createElement('span');
        unitLabel.classList.add('duration-control-label');
        unitLabel.textContent = label;

        group.appendChild(input);
        group.appendChild(unitLabel);

        return group;
    }

    private get durationFields(): DurationFields {
        if (!this._durationFields) {
            this._durationFields = {
                hours: this.createDurationField('hours', 12),
                minutes: this.createDurationField('minutes', 59),
                seconds: this.createDurationField('seconds', 59)
            };
        }

        return this._durationFields;
    }

    private get durationInputRow(): HTMLElement {
        if (!this._durationInputRow) {
            const fields = this.durationFields;
            this._durationInputRow = document.createElement('div');
            this._durationInputRow.classList.add('duration-control');
            this._durationInputRow.title = `${this.setting.description} Maximum 12 hours.`;
            this._durationInputRow.appendChild(this.createDurationFieldGroup('h', fields.hours));
            this._durationInputRow.appendChild(this.createDurationFieldGroup('min', fields.minutes));
            this._durationInputRow.appendChild(this.createDurationFieldGroup('sec', fields.seconds));
        }

        return this._durationInputRow;
    }

    /**
     * @returns Return or creates a HTML element that represents this setting in the DOM.
     */
    public override get rootElement(): HTMLElement {
        if (!this._rootElement) {
            // create root div with "setting" css class
            this._rootElement = document.createElement('div');
            this._rootElement.classList.add('setting');
            this._rootElement.classList.add('form-group');

            // create div element to contain our setting's text
            this._rootElement.appendChild(this.settingsTextElem);

            if (this.isAfkTimeoutSetting) {
                this._rootElement.classList.add('duration-form-group');
                this._rootElement.appendChild(this.durationInputRow);
            } else {
                // create label element to wrap out input type
                this._rootElement.appendChild(this.spinner);

                // setup onchange
                this.spinner.onchange = (event: Event) => {
                    const inputElem = event.target as HTMLInputElement;

                    const parsedValue = Number.parseFloat(inputElem.value);

                    if (Number.isNaN(parsedValue)) {
                        Logger.Warning(
                            `Could not parse value change into a valid number - value was ${inputElem.value}, resetting value to ${this.setting.min}`
                        );
                        if (this.setting.number !== this.setting.min) {
                            this.setting.number = this.setting.min;
                        }
                    } else {
                        if (this.setting.number !== parsedValue) {
                            this.setting.number = parsedValue;
                            this.setting.updateURLParams();
                        }
                    }
                };
            }
        }
        return this._rootElement;
    }

    private getDurationFieldValue(input: HTMLInputElement): number | null {
        const parsedValue = Number.parseInt(input.value, 10);
        if (Number.isNaN(parsedValue) || parsedValue < 0) {
            return null;
        }

        return parsedValue;
    }

    private commitDurationFields(): void {
        const fields = this.durationFields;
        const hours = this.getDurationFieldValue(fields.hours);
        const minutes = this.getDurationFieldValue(fields.minutes);
        const seconds = this.getDurationFieldValue(fields.seconds);

        if (hours == null || minutes == null || seconds == null) {
            Logger.Warning(
                'Could not parse AFK timeout into a valid duration, resetting to the current value.'
            );
            this.updateDurationFields(this.setting.number);
            return;
        }

        const totalSeconds = hours * 60 * 60 + minutes * 60 + seconds;
        const clampedSeconds = this.setting.clamp(totalSeconds);

        if (this.setting.number !== clampedSeconds) {
            this.setting.number = clampedSeconds;
            this.setting.updateURLParams();
        }

        this.updateDurationFields(clampedSeconds);
    }

    private updateDurationFields(newNumber: number): void {
        const fields = this.durationFields;
        const totalSeconds = Math.floor(this.setting.clamp(newNumber));
        const hours = Math.floor(totalSeconds / 3600);
        const minutes = Math.floor((totalSeconds % 3600) / 60);
        const seconds = totalSeconds % 60;

        fields.hours.value = hours.toString();
        fields.minutes.value = minutes.toString();
        fields.seconds.value = seconds.toString();
    }

    private setDurationFieldsDisabled(disabled: boolean): void {
        const fields = this.durationFields;
        fields.hours.disabled = disabled;
        fields.minutes.disabled = disabled;
        fields.seconds.disabled = disabled;
    }

    /**
     * Set the number in the spinner (will be clamped within range).
     */
    public set number(newNumber: number) {
        if (this.isAfkTimeoutSetting) {
            this.updateDurationFields(newNumber);
            return;
        }

        this.spinner.value = this.setting.clamp(newNumber).toString();
    }

    /**
     * Get value
     */
    public get number() {
        if (this.isAfkTimeoutSetting) {
            const fields = this.durationFields;
            const hours = this.getDurationFieldValue(fields.hours) ?? 0;
            const minutes = this.getDurationFieldValue(fields.minutes) ?? 0;
            const seconds = this.getDurationFieldValue(fields.seconds) ?? 0;
            return this.setting.clamp(hours * 60 * 60 + minutes * 60 + seconds);
        }

        return +this.spinner.value;
    }

    /**
     * Set the label text for the setting.
     * @param label - setting label.
     */
    public set label(inLabel: string) {
        this.settingsTextElem.innerText = inLabel;
    }

    /**
     * Get label
     */
    public get label() {
        return this.settingsTextElem.innerText;
    }

    public disable(): void {
        if (this.isAfkTimeoutSetting) {
            this.setDurationFieldsDisabled(true);
            return;
        }

        this.spinner.disabled = true;
    }

    public enable(): void {
        if (this.isAfkTimeoutSetting) {
            this.setDurationFieldsDisabled(false);
            return;
        }

        this.spinner.disabled = false;
    }
}
