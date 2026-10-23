/** Reveal conversion controls without letting scrollIntoView move player ancestors.
 * Settings animates horizontally, so vertical positioning is already valid while
 * it opens. No delayed callback can scroll after the user closes the panel.
 */
export function showRecordingSettings(settings: { rootElement: HTMLElement; show(): void }, section: HTMLElement): void {
    if (section.hidden) section.parentElement?.querySelector<HTMLElement>('.settingsSectionHeader')?.click();
    settings.show();
    const target = section.querySelector<HTMLElement>('#recordingMp4');
    const panel = settings.rootElement;
    if (!target || !panel.isConnected) return;
    const bounds = panel.getBoundingClientRect();
    const content = target.getBoundingClientRect();
    const scale = panel.offsetHeight > 0 ? bounds.height / panel.offsetHeight : 1;
    if (!scale || !Number.isFinite(scale)) return;
    const top = bounds.top + panel.clientTop * scale;
    const bottom = top + panel.clientHeight * scale;
    const delta = content.height > bottom - top || content.top < top ? content.top - top :
        content.bottom > bottom ? content.bottom - bottom : 0;
    panel.scrollTop += delta / scale;
}
