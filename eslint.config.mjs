// Copyright Epic Games, Inc. All Rights Reserved.

import eslint from '@eslint/js';
import prettierPluginRecommended from 'eslint-plugin-prettier/recommended';
import tseslint from 'typescript-eslint';
import checkCopyrightPlugin from './Extras/eslint/plugin-check-copyright/index.js'

export default tseslint.config(
    eslint.configs.recommended,
    tseslint.configs.recommendedTypeCheckedOnly,
    prettierPluginRecommended,
    {
        plugins: {
            'copyright': checkCopyrightPlugin
        },
        rules: {
            "prettier/prettier": ["error", { endOfLine: "auto" }],
            "copyright/copyright": [
                "error",
                {
                    notice: "Copyright Epic Games, Inc. All Rights Reserved."
                }
            ]
        }
    }
);
