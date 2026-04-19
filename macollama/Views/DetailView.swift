import SwiftUI
import MarkdownUI

struct DetailView: View {
    @Binding var selectedModel: String?
    @Binding var isLoadingModels: Bool
    @ObservedObject private var viewModel = ChatViewModel.shared
    @Namespace private var bottomID
    @State private var isGenerating = false  
    @State private var responseStartTime: Date? 
    @State private var tokenCount: Int = 0 
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(viewModel.messages) { message in
                            VStack(alignment: .trailing, spacing: 4) {
                                MessageBubble(message: message)
                            }
                            .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding()
                }
                .onReceive(viewModel.$messages) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            MessageInputView(
                viewModel: viewModel,
                selectedModel: $selectedModel,
                isGenerating: $isGenerating,
                isLoadingModels: $isLoadingModels,
                onSendMessage: sendMessage,
                onCancelGeneration: {
                    LLMService.shared.cancelGeneration()
                    isGenerating = false
                }
            )
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
    
    private func sendMessage() {
        guard let selectedModel = selectedModel,
              !viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        let currentText = viewModel.messageText
        let currentImage = viewModel.selectedImage
        
        viewModel.messageText = ""
        viewModel.selectedImage = nil
        isGenerating = true  
        
        responseStartTime = Date() 
        tokenCount = 0 
        
        let userMessage = ChatMessage(
            id: viewModel.messages.count * 2,
            content: currentText,
            isUser: true,
            timestamp: Date(),
            image: currentImage,
            engine: selectedModel
        )
        
        let waitingMessage = ChatMessage(
            id: viewModel.messages.count * 2 + 1,
            content: "...",
            isUser: false,
            timestamp: Date(),
            image: nil,
            engine: selectedModel
        )
        DispatchQueue.main.async {
            viewModel.addMessage(userMessage)
            viewModel.addMessage(waitingMessage)

            Task {
                do {
                    var fullResponse = ""
                    var firstTokenTime: Date?
                    let stream = try await LLMService.shared.generateResponse(
                        prompt: currentText,
                        image: currentImage,
                        model: selectedModel
                    )
                    
                    for try await response in stream {
                        if firstTokenTime == nil && !response.isEmpty {
                            firstTokenTime = Date()
                        }
                        fullResponse += response
                        tokenCount += response.count

                        viewModel.updateLastAssistantMessage(
                            content: fullResponse,
                            engine: selectedModel
                        )
                    }
                    
                    var statsMessage = ""
                    if let startTime = responseStartTime {
                        let endTime = Date()
                        let thinkingTime = max((firstTokenTime ?? endTime).timeIntervalSince(startTime), 0)
                        let responseTime = max(endTime.timeIntervalSince(firstTokenTime ?? endTime), 0)
                        let tokenRateBase = max(responseTime, 0.001)
                        let tokensPerSecond = Double(tokenCount) / tokenRateBase
                        statsMessage = "\n\n---\n [\(selectedModel)] \(String(format: "%.1f", tokensPerSecond)) tokens/sec · Time: thinking \(String(format: "%.2f", thinkingTime))s, response \(String(format: "%.2f", responseTime))s"

                        viewModel.updateLastAssistantMessage(
                            content: fullResponse + statsMessage,
                            engine: selectedModel
                        )
                    }
                    
                    try DatabaseManager.shared.insert(
                        groupId: viewModel.chatId.uuidString,
                        instruction: UserDefaults.standard.string(forKey: "llmInstruction") ?? "",
                        question: currentText,
                        answer: fullResponse + statsMessage,
                        image: currentImage,
                        engine: selectedModel
                    )
                    
                    Task { @MainActor in
                        await SidebarViewModel.shared.refresh()
                    }
                    
                } catch {
                    if let index = viewModel.messages.lastIndex(where: { !$0.isUser }) {
                        viewModel.updateLastAssistantMessage(
                            content: "\(error.localizedDescription)",
                            engine: selectedModel
                        )
                    }
                }
                
                isGenerating = false
                responseStartTime = nil
                tokenCount = 0 
            }
        }
    }
}
