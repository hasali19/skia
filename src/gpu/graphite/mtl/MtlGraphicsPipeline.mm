/*
 * Copyright 2021 Google LLC
 *
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

#include "src/gpu/graphite/mtl/MtlGraphicsPipeline.h"

#include "include/core/SkSpan.h"
#include "include/gpu/ShaderErrorHandler.h"
#include "include/gpu/graphite/TextureInfo.h"
#include "src/core/SkPipelineData.h"
#include "src/core/SkSLTypeShared.h"
#include "src/gpu/graphite/ContextUtils.h"
#include "src/gpu/graphite/GraphicsPipelineDesc.h"
#include "src/gpu/graphite/Log.h"
#include "src/gpu/graphite/Renderer.h"
#include "src/gpu/graphite/UniformManager.h"
#include "src/gpu/graphite/mtl/MtlGpu.h"
#include "src/gpu/graphite/mtl/MtlResourceProvider.h"
#include "src/gpu/graphite/mtl/MtlUtils.h"

#include "src/gpu/tessellate/WangsFormula.h"

namespace skgpu::graphite {

namespace {

inline MTLVertexFormat attribute_type_to_mtlformat(VertexAttribType type) {
    switch (type) {
        case VertexAttribType::kFloat:
            return MTLVertexFormatFloat;
        case VertexAttribType::kFloat2:
            return MTLVertexFormatFloat2;
        case VertexAttribType::kFloat3:
            return MTLVertexFormatFloat3;
        case VertexAttribType::kFloat4:
            return MTLVertexFormatFloat4;
        case VertexAttribType::kHalf:
            if (@available(macOS 10.13, iOS 11.0, *)) {
                return MTLVertexFormatHalf;
            } else {
                return MTLVertexFormatInvalid;
            }
        case VertexAttribType::kHalf2:
            return MTLVertexFormatHalf2;
        case VertexAttribType::kHalf4:
            return MTLVertexFormatHalf4;
        case VertexAttribType::kInt2:
            return MTLVertexFormatInt2;
        case VertexAttribType::kInt3:
            return MTLVertexFormatInt3;
        case VertexAttribType::kInt4:
            return MTLVertexFormatInt4;
        case VertexAttribType::kByte:
            if (@available(macOS 10.13, iOS 11.0, *)) {
                return MTLVertexFormatChar;
            } else {
                return MTLVertexFormatInvalid;
            }
        case VertexAttribType::kByte2:
            return MTLVertexFormatChar2;
        case VertexAttribType::kByte4:
            return MTLVertexFormatChar4;
        case VertexAttribType::kUByte:
            if (@available(macOS 10.13, iOS 11.0, *)) {
                return MTLVertexFormatUChar;
            } else {
                return MTLVertexFormatInvalid;
            }
        case VertexAttribType::kUByte2:
            return MTLVertexFormatUChar2;
        case VertexAttribType::kUByte4:
            return MTLVertexFormatUChar4;
        case VertexAttribType::kUByte_norm:
            if (@available(macOS 10.13, iOS 11.0, *)) {
                return MTLVertexFormatUCharNormalized;
            } else {
                return MTLVertexFormatInvalid;
            }
        case VertexAttribType::kUByte4_norm:
            return MTLVertexFormatUChar4Normalized;
        case VertexAttribType::kShort2:
            return MTLVertexFormatShort2;
        case VertexAttribType::kShort4:
            return MTLVertexFormatShort4;
        case VertexAttribType::kUShort2:
            return MTLVertexFormatUShort2;
        case VertexAttribType::kUShort2_norm:
            return MTLVertexFormatUShort2Normalized;
        case VertexAttribType::kInt:
            return MTLVertexFormatInt;
        case VertexAttribType::kUInt:
            return MTLVertexFormatUInt;
        case VertexAttribType::kUShort_norm:
            if (@available(macOS 10.13, iOS 11.0, *)) {
                return MTLVertexFormatUShortNormalized;
            } else {
                return MTLVertexFormatInvalid;
            }
        case VertexAttribType::kUShort4_norm:
            return MTLVertexFormatUShort4Normalized;
    }
    SK_ABORT("Unknown vertex attribute type");
}

MTLVertexDescriptor* create_vertex_descriptor(const RenderStep* step) {
    auto vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    int attributeIndex = 0;

    int vertexAttributeCount = step->numVertexAttributes();
    size_t vertexAttributeOffset = 0;
    for (const auto& attribute : step->vertexAttributes()) {
        MTLVertexAttributeDescriptor* mtlAttribute = vertexDescriptor.attributes[attributeIndex];
        MTLVertexFormat format = attribute_type_to_mtlformat(attribute.cpuType());
        SkASSERT(MTLVertexFormatInvalid != format);
        mtlAttribute.format = format;
        mtlAttribute.offset = vertexAttributeOffset;
        mtlAttribute.bufferIndex = MtlGraphicsPipeline::kVertexBufferIndex;

        vertexAttributeOffset += attribute.sizeAlign4();
        attributeIndex++;
    }
    SkASSERT(vertexAttributeOffset == step->vertexStride());

    if (vertexAttributeCount) {
        MTLVertexBufferLayoutDescriptor* vertexBufferLayout =
                vertexDescriptor.layouts[MtlGraphicsPipeline::kVertexBufferIndex];
        vertexBufferLayout.stepFunction = MTLVertexStepFunctionPerVertex;
        vertexBufferLayout.stepRate = 1;
        vertexBufferLayout.stride = vertexAttributeOffset;
    }

    int instanceAttributeCount = step->numInstanceAttributes();
    size_t instanceAttributeOffset = 0;
    for (const auto& attribute : step->instanceAttributes()) {
        MTLVertexAttributeDescriptor* mtlAttribute = vertexDescriptor.attributes[attributeIndex];
        MTLVertexFormat format = attribute_type_to_mtlformat(attribute.cpuType());
        SkASSERT(MTLVertexFormatInvalid != format);
        mtlAttribute.format = format;
        mtlAttribute.offset = instanceAttributeOffset;
        mtlAttribute.bufferIndex = MtlGraphicsPipeline::kInstanceBufferIndex;

        instanceAttributeOffset += attribute.sizeAlign4();
        attributeIndex++;
    }
    SkASSERT(instanceAttributeOffset == step->instanceStride());

    if (instanceAttributeCount) {
        MTLVertexBufferLayoutDescriptor* instanceBufferLayout =
                vertexDescriptor.layouts[MtlGraphicsPipeline::kInstanceBufferIndex];
        instanceBufferLayout.stepFunction = MTLVertexStepFunctionPerInstance;
        instanceBufferLayout.stepRate = 1;
        instanceBufferLayout.stride = instanceAttributeOffset;
    }
    return vertexDescriptor;
}

// TODO: share this w/ Ganesh Metal backend?
static MTLBlendFactor blend_coeff_to_mtl_blend(skgpu::BlendCoeff coeff) {
    switch (coeff) {
        case skgpu::BlendCoeff::kZero:
            return MTLBlendFactorZero;
        case skgpu::BlendCoeff::kOne:
            return MTLBlendFactorOne;
        case skgpu::BlendCoeff::kSC:
            return MTLBlendFactorSourceColor;
        case skgpu::BlendCoeff::kISC:
            return MTLBlendFactorOneMinusSourceColor;
        case skgpu::BlendCoeff::kDC:
            return MTLBlendFactorDestinationColor;
        case skgpu::BlendCoeff::kIDC:
            return MTLBlendFactorOneMinusDestinationColor;
        case skgpu::BlendCoeff::kSA:
            return MTLBlendFactorSourceAlpha;
        case skgpu::BlendCoeff::kISA:
            return MTLBlendFactorOneMinusSourceAlpha;
        case skgpu::BlendCoeff::kDA:
            return MTLBlendFactorDestinationAlpha;
        case skgpu::BlendCoeff::kIDA:
            return MTLBlendFactorOneMinusDestinationAlpha;
        case skgpu::BlendCoeff::kConstC:
            return MTLBlendFactorBlendColor;
        case skgpu::BlendCoeff::kIConstC:
            return MTLBlendFactorOneMinusBlendColor;
        case skgpu::BlendCoeff::kS2C:
            if (@available(macOS 10.12, iOS 11.0, *)) {
                return MTLBlendFactorSource1Color;
            } else {
                return MTLBlendFactorZero;
            }
        case skgpu::BlendCoeff::kIS2C:
            if (@available(macOS 10.12, iOS 11.0, *)) {
                return MTLBlendFactorOneMinusSource1Color;
            } else {
                return MTLBlendFactorZero;
            }
        case skgpu::BlendCoeff::kS2A:
            if (@available(macOS 10.12, iOS 11.0, *)) {
                return MTLBlendFactorSource1Alpha;
            } else {
                return MTLBlendFactorZero;
            }
        case skgpu::BlendCoeff::kIS2A:
            if (@available(macOS 10.12, iOS 11.0, *)) {
                return MTLBlendFactorOneMinusSource1Alpha;
            } else {
                return MTLBlendFactorZero;
            }
        case skgpu::BlendCoeff::kIllegal:
            return MTLBlendFactorZero;
    }

    SK_ABORT("Unknown blend coefficient");
}

// TODO: share this w/ Ganesh Metal backend?
static MTLBlendOperation blend_equation_to_mtl_blend_op(skgpu::BlendEquation equation) {
    static const MTLBlendOperation gTable[] = {
            MTLBlendOperationAdd,              // skgpu::BlendEquation::kAdd
            MTLBlendOperationSubtract,         // skgpu::BlendEquation::kSubtract
            MTLBlendOperationReverseSubtract,  // skgpu::BlendEquation::kReverseSubtract
    };
    static_assert(std::size(gTable) == (int)skgpu::BlendEquation::kFirstAdvanced);
    static_assert(0 == (int)skgpu::BlendEquation::kAdd);
    static_assert(1 == (int)skgpu::BlendEquation::kSubtract);
    static_assert(2 == (int)skgpu::BlendEquation::kReverseSubtract);

    SkASSERT((unsigned)equation < skgpu::kBlendEquationCnt);
    return gTable[(int)equation];
}

static MTLRenderPipelineColorAttachmentDescriptor* create_color_attachment(
        MTLPixelFormat format,
        const BlendInfo& blendInfo) {

    skgpu::BlendEquation equation = blendInfo.fEquation;
    skgpu::BlendCoeff srcCoeff = blendInfo.fSrcBlend;
    skgpu::BlendCoeff dstCoeff = blendInfo.fDstBlend;
    bool blendOn = !skgpu::BlendShouldDisable(equation, srcCoeff, dstCoeff);

    // TODO: I *think* this gets cleaned up by the pipelineDescriptor?
    auto mtlColorAttachment = [[MTLRenderPipelineColorAttachmentDescriptor alloc] init];

    mtlColorAttachment.pixelFormat = format;

    mtlColorAttachment.blendingEnabled = blendOn;

    if (blendOn) {
        mtlColorAttachment.sourceRGBBlendFactor = blend_coeff_to_mtl_blend(srcCoeff);
        mtlColorAttachment.destinationRGBBlendFactor = blend_coeff_to_mtl_blend(dstCoeff);
        mtlColorAttachment.rgbBlendOperation = blend_equation_to_mtl_blend_op(equation);
        mtlColorAttachment.sourceAlphaBlendFactor = blend_coeff_to_mtl_blend(srcCoeff);
        mtlColorAttachment.destinationAlphaBlendFactor = blend_coeff_to_mtl_blend(dstCoeff);
        mtlColorAttachment.alphaBlendOperation = blend_equation_to_mtl_blend_op(equation);
    }

    mtlColorAttachment.writeMask = blendInfo.fWritesColor ? MTLColorWriteMaskAll
                                                          : MTLColorWriteMaskNone;

    return mtlColorAttachment;
}

} // anonymous namespace

enum ShaderType {
    kVertex_ShaderType = 0,
    kFragment_ShaderType = 1,

    kLast_ShaderType = kFragment_ShaderType
};
static const int kShaderTypeCount = kLast_ShaderType + 1;

sk_sp<MtlGraphicsPipeline> MtlGraphicsPipeline::Make(
        MtlResourceProvider* resourceProvider, const MtlGpu* gpu,
        const GraphicsPipelineDesc& pipelineDesc,
        const RenderPassDesc& renderPassDesc) {
    sk_cfp<MTLRenderPipelineDescriptor*> psoDescriptor([[MTLRenderPipelineDescriptor alloc] init]);

    std::string msl[kShaderTypeCount];
    SkSL::Program::Inputs inputs[kShaderTypeCount];
    SkSL::Program::Settings settings;

    settings.fForceNoRTFlip = true;

    ShaderErrorHandler* errorHandler = gpu->caps()->shaderErrorHandler();
    if (!SkSLToMSL(gpu,
                   GetSkSLVS(pipelineDesc),
                   SkSL::ProgramKind::kGraphiteVertex,
                   settings,
                   &msl[kVertex_ShaderType],
                   &inputs[kVertex_ShaderType],
                   errorHandler)) {
        return nullptr;
    }

    BlendInfo blendInfo;
    auto dict = resourceProvider->shaderCodeDictionary();
    if (!SkSLToMSL(gpu,
                   GetSkSLFS(dict, resourceProvider->runtimeEffectDictionary(),
                             pipelineDesc, &blendInfo),
                   SkSL::ProgramKind::kGraphiteFragment,
                   settings,
                   &msl[kFragment_ShaderType],
                   &inputs[kFragment_ShaderType],
                   errorHandler)) {
        return nullptr;
    }

    sk_cfp<id<MTLLibrary>> shaderLibraries[kShaderTypeCount];

    shaderLibraries[kVertex_ShaderType] = MtlCompileShaderLibrary(gpu,
                                                                  msl[kVertex_ShaderType],
                                                                  errorHandler);
    shaderLibraries[kFragment_ShaderType] = MtlCompileShaderLibrary(gpu,
                                                                    msl[kFragment_ShaderType],
                                                                    errorHandler);
    if (!shaderLibraries[kVertex_ShaderType] || !shaderLibraries[kFragment_ShaderType]) {
        return nullptr;
    }

    (*psoDescriptor).label = @(pipelineDesc.renderStep()->name());

    (*psoDescriptor).vertexFunction =
            [shaderLibraries[kVertex_ShaderType].get() newFunctionWithName: @"vertexMain"];
    (*psoDescriptor).fragmentFunction =
            [shaderLibraries[kFragment_ShaderType].get() newFunctionWithName: @"fragmentMain"];

    // TODO: I *think* this gets cleaned up by the pipelineDescriptor?
    (*psoDescriptor).vertexDescriptor = create_vertex_descriptor(pipelineDesc.renderStep());

    const MtlTextureSpec& mtlColorSpec =
            renderPassDesc.fColorAttachment.fTextureInfo.mtlTextureSpec();
    auto mtlColorAttachment = create_color_attachment((MTLPixelFormat)mtlColorSpec.fFormat,
                                                      blendInfo);
    (*psoDescriptor).colorAttachments[0] = mtlColorAttachment;

    (*psoDescriptor).sampleCount = renderPassDesc.fColorAttachment.fTextureInfo.numSamples();

    const MtlTextureSpec& mtlDSSpec =
            renderPassDesc.fDepthStencilAttachment.fTextureInfo.mtlTextureSpec();
    MTLPixelFormat depthStencilFormat = (MTLPixelFormat)mtlDSSpec.fFormat;
    if (MtlFormatIsStencil(depthStencilFormat)) {
        (*psoDescriptor).stencilAttachmentPixelFormat = depthStencilFormat;
    } else {
        (*psoDescriptor).stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
    }
    if (MtlFormatIsDepth(depthStencilFormat)) {
        (*psoDescriptor).depthAttachmentPixelFormat = depthStencilFormat;
    } else {
        (*psoDescriptor).depthAttachmentPixelFormat = MTLPixelFormatInvalid;
    }

    NSError* error;
    sk_cfp<id<MTLRenderPipelineState>> pso(
            [gpu->device() newRenderPipelineStateWithDescriptor:psoDescriptor.get()
                                                          error:&error]);
    if (!pso) {
        SKGPU_LOG_E("Pipeline creation failure:\n%s", error.debugDescription.UTF8String);
        return nullptr;
    }

    const DepthStencilSettings& depthStencilSettings =
            pipelineDesc.renderStep()->depthStencilSettings();
    sk_cfp<id<MTLDepthStencilState>> dss =
            resourceProvider->findOrCreateCompatibleDepthStencilState(depthStencilSettings);

    return sk_sp<MtlGraphicsPipeline>(
            new MtlGraphicsPipeline(gpu,
                                    std::move(pso),
                                    std::move(dss),
                                    depthStencilSettings.fStencilReferenceValue,
                                    pipelineDesc.renderStep()->vertexStride(),
                                    pipelineDesc.renderStep()->instanceStride()));
}

void MtlGraphicsPipeline::freeGpuData() {
    fPipelineState.reset();
}

} // namespace skgpu::graphite
