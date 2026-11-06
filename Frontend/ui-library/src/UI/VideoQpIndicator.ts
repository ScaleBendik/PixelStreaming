// Copyright Epic Games, Inc. All Rights Reserved.

import { VideoQPIndicatorConfig } from '../Application/Application';

/**
 * Estimates encoding quality from the last encoder QP (quantization parameter).
 * AV1 and H.264 use separate thresholds; unsupported codecs remain unrated.
 */
export class VideoQpIndicator {
    config?: VideoQPIndicatorConfig;

    videoEncoderAvgQP = -1;
    private videoCodec?: string;
    private connected = false;
    private blinkInterval?: ReturnType<typeof setInterval>;

    // non html elements
    statsText = '';
    color = '';

    // Legacy H.264 thresholds; these are not a perceptual quality score.
    readonly orangeQP = 26;
    readonly redQP = 35;

    // AV1 reports a 0–255 qindex. Chromium's hardware AV1 encoder uses these
    // quality-scaling bounds for low/high quantization pressure:
    // https://chromium.googlesource.com/chromium/src/+/HEAD/third_party/blink/renderer/platform/peerconnection/rtc_video_encoder.cc
    // They provide a codec-specific heuristic, not a perceptual quality score.
    readonly av1OrangeQP = 145;
    readonly av1RedQP = 205;

    _rootElement: HTMLElement;
    _qualityText: HTMLElement;
    _qualityStatus: SVGElement;
    _dot: SVGElement;
    _outer: SVGElement;
    _middle: SVGElement;
    _inner: SVGElement;

    constructor(config?: VideoQPIndicatorConfig) {
        this.config = config;
    }

    /**
     * Get the root element of the QP indicator.
     */
    public get rootElement(): HTMLElement {
        if (!this._rootElement) {
            // make the root element that contains the svg for the connection
            this._rootElement = document.createElement('div');
            this._rootElement.id = 'connection';
            this._rootElement.classList.add('UiTool');

            // add svg icon for the connection strength
            this._rootElement.appendChild(this.qualityStatus);

            // add the text underneath the connection
            this._rootElement.appendChild(this.qualityText);

            // set colors to not connected initially
            this.render();
        }
        return this._rootElement;
    }

    /**
     * Get the text that displays under the icon.
     */
    public get qualityText(): HTMLElement {
        if (!this._qualityText) {
            this._qualityText = document.createElement('span');
            this._qualityText.id = 'qualityText';
            this._qualityText.classList.add('tooltiptext');
        }
        return this._qualityText;
    }

    /**
     * Get the icon.
     */
    public get qualityStatus(): SVGElement {
        if (!this._qualityStatus) {
            this._qualityStatus = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
            this._qualityStatus.setAttributeNS(null, 'id', 'connectionStrength');
            this._qualityStatus.setAttributeNS(null, 'x', '0px');
            this._qualityStatus.setAttributeNS(null, 'y', '0px');
            this._qualityStatus.setAttributeNS(null, 'viewBox', '0 0 494.45 494.45');

            // build wifi icon
            this.qualityStatus.appendChild(this.dot);
            this.qualityStatus.appendChild(this.middle);
            this.qualityStatus.appendChild(this.outer);
            this.qualityStatus.appendChild(this.inner);
        }
        return this._qualityStatus;
    }

    /**
     * Get the dot at the bottom of the wifi icon.
     */
    public get dot(): SVGElement {
        if (!this._dot) {
            this._dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
            this._dot.setAttributeNS(null, 'id', 'dot');
            this._dot.setAttributeNS(null, 'cx', '247.125');
            this._dot.setAttributeNS(null, 'cy', '398.925');
            this._dot.setAttributeNS(null, 'r', '35.3');
        }
        return this._dot;
    }

    /**
     * Get the outer arc of the wifi icon.
     */
    public get outer(): SVGElement {
        if (!this._outer) {
            this._outer = document.createElementNS('http://www.w3.org/2000/svg', 'path');
            this._outer.setAttributeNS(null, 'id', 'outer');
            this._outer.setAttributeNS(
                null,
                'd',
                'M467.925,204.625c-6.8,0-13.5-2.6-18.7-7.8c-111.5-111.4-292.7-111.4-404.1,0c-10.3,10.3-27.1,10.3-37.4,0s-10.3-27.1,0-37.4c64-64,149-99.2,239.5-99.2s175.5,35.2,239.5,99.2c10.3,10.3,10.3,27.1,0,37.4C481.425,202.025,474.625,204.625,467.925,204.625z'
            );
        }
        return this._outer;
    }

    /**
     * Get the middle arc of the wifi icon.
     */
    public get middle(): SVGElement {
        if (!this._middle) {
            this._middle = document.createElementNS('http://www.w3.org/2000/svg', 'path');
            this._middle.setAttributeNS(null, 'id', 'middle');
            this._middle.setAttributeNS(
                null,
                'd',
                'M395.225,277.325c-6.8,0-13.5-2.6-18.7-7.8c-71.4-71.3-187.4-71.3-258.8,0c-10.3,10.3-27.1,10.3-37.4,0s-10.3-27.1,0-37.4c92-92,241.6-92,333.6,0c10.3,10.3,10.3,27.1,0,37.4C408.725,274.725,401.925,277.325,395.225,277.325z'
            );
        }
        return this._middle;
    }

    /**
     * Get the inner arc of the wifi icon.
     */
    public get inner(): SVGElement {
        if (!this._inner) {
            this._inner = document.createElementNS('http://www.w3.org/2000/svg', 'path');
            this._inner.setAttributeNS(null, 'id', 'inner');
            this._inner.setAttributeNS(
                null,
                'd',
                'M323.625,348.825c-6.8,0-13.5-2.6-18.7-7.8c-15.4-15.4-36-23.9-57.8-23.9s-42.4,8.5-57.8,23.9c-10.3,10.3-27.1,10.3-37.4,0c-10.3-10.3-10.3-27.1,0-37.4c25.4-25.4,59.2-39.4,95.2-39.4s69.8,14,95.2,39.5c10.3,10.3,10.3,27.1,0,37.4C337.225,346.225,330.425,348.825,323.625,348.825z'
            );
        }
        return this._inner;
    }

    /**
     * Used to set the speed of the status light.
     * @param speed - Set the speed of the blink, higher numbers make the status light blink faster.
     */
    blinkVideoQualityStatus(speed: number) {
        let iteration = speed;
        let opacity = 1;
        this.blinkInterval = setInterval(() => {
            opacity -= 0.1;
            this.qualityText.style.opacity = String(Math.abs((opacity - 0.5) * 2));
            if (opacity <= 0.1) {
                if (--iteration === 0) {
                    clearInterval(this.blinkInterval);
                    this.blinkInterval = undefined;
                } else {
                    opacity = 1;
                }
            }
        }, 100 / speed);
    }

    /** Reset codec and QP at the connection boundary so a new peer cannot inherit a rating. */
    setConnected(connected: boolean) {
        this.connected = connected;
        if (!connected) {
            this.videoCodec = undefined;
            this.videoEncoderAvgQP = -1;
        }
        this.render();
    }

    /** Use the actual inbound video codec from RTC stats, never the preferred codec. */
    updateVideoCodec(mimeType?: string) {
        const codec = mimeType?.trim().toLowerCase();
        this.videoCodec =
            codec === 'video/h264'
                ? 'H.264'
                : codec === 'video/av1'
                  ? 'AV1'
                  : codec === 'video/vp9'
                    ? 'VP9'
                    : codec === 'video/vp8'
                      ? 'VP8'
                      : undefined;
        this.render();
    }

    updateQpTooltip(QP: number) {
        this.videoEncoderAvgQP = QP;
        this.render();
    }

    private render() {
        clearInterval(this.blinkInterval);
        this.blinkInterval = undefined;
        this.qualityText.style.opacity = '1';
        this.qualityStatus.style.opacity = '1';
        const QP = this.videoEncoderAvgQP;
        const isAv1 = this.videoCodec === 'AV1';
        const maxQP = isAv1 ? 255 : this.videoCodec === 'H.264' ? 51 : undefined;
        const orangeQP = isAv1 ? this.av1OrangeQP : this.orangeQP;
        const redQP = isAv1 ? this.av1RedQP : this.redQP;
        if (!this.connected || !Number.isFinite(QP) || QP < 0 || (maxQP !== undefined && QP > maxQP)) {
            this.color = '#b0b0b0';
            this.outer.setAttributeNS(null, 'fill', '#3c3b40');
            this.middle.setAttributeNS(null, 'fill', '#3c3b40');
            this.inner.setAttributeNS(null, 'fill', '#3c3b40');
            this.dot.setAttributeNS(null, 'fill', '#3c3b40');
            this.statsText = `<div style="color: ${this.color}">${
                this.connected ? 'Waiting for encoder statistics' : 'Not connected'
            }</div>`;
        } else if (this.videoCodec !== 'H.264' && !isAv1) {
            this.color = '#b0b0b0';
            this.statsText = `<div style="color: ${this.color}">${
                this.videoCodec ?? 'Unknown codec'
            } QP: ${QP} (quality not rated)</div>`;
            this.outer.setAttributeNS(null, 'fill', this.color);
            this.middle.setAttributeNS(null, 'fill', this.color);
            this.inner.setAttributeNS(null, 'fill', this.color);
            this.dot.setAttributeNS(null, 'fill', this.color);
        } else if (QP > redQP) {
            this.color = 'red';
            this.blinkVideoQualityStatus(2);
            this.statsText = `<div style="color: ${this.color}">${
                isAv1
                    ? `Poor AV1 encoding quality (QP ${QP}; estimated)`
                    : `High H.264 quantization (QP ${QP})`
            }</div>`;
            this.outer.setAttributeNS(null, 'fill', '#3c3b40');
            this.middle.setAttributeNS(null, 'fill', '#3c3b40');
            this.inner.setAttributeNS(null, 'fill', this.color);
            this.dot.setAttributeNS(null, 'fill', this.color);
        } else if (QP > orangeQP) {
            this.color = 'orange';
            this.blinkVideoQualityStatus(1);
            this.statsText = `<div style="color: ${this.color}">${
                isAv1
                    ? `Reduced AV1 encoding quality (QP ${QP}; estimated)`
                    : `Moderate H.264 quantization (QP ${QP})`
            }</div>`;
            this.outer.setAttributeNS(null, 'fill', '#3c3b40');
            this.middle.setAttributeNS(null, 'fill', this.color);
            this.inner.setAttributeNS(null, 'fill', this.color);
            this.dot.setAttributeNS(null, 'fill', this.color);
        } else {
            this.color = 'lime';
            this.qualityStatus.style.opacity = this.config?.hideWhenGood === true ? '0' : '1';
            this.statsText = `<div style="color: ${this.color}">${
                isAv1
                    ? `Good AV1 encoding quality (QP ${QP}; estimated)`
                    : `Low H.264 quantization (QP ${QP})`
            }</div>`;
            this.outer.setAttributeNS(null, 'fill', this.color);
            this.middle.setAttributeNS(null, 'fill', this.color);
            this.inner.setAttributeNS(null, 'fill', this.color);
            this.dot.setAttributeNS(null, 'fill', this.color);
        }
        this.qualityText.innerHTML = this.statsText;
    }
}
