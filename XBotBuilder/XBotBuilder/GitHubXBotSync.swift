//
//  GitHubXBotSync.swift
//  XBotBuilder
//
//  Created by Geoffrey Nix on 10/7/14.
//  Copyright (c) 2014 ModCloth. All rights reserved.
//

import Foundation
import XBot

struct BotPRPair {
    var bot:XBot.Bot?
    var pr:GitHubPullRequest?
}

class GitHubXBotSync {

    var botServer:XBot.Server
    var gitHubRepo:GitHubRepo
    var botConfigTemplate:BotConfigTemplate
    
    init(botServer:XBot.Server, gitHubRepo:GitHubRepo, botConfigTemplate:BotConfigTemplate){
        self.botServer = botServer
        self.gitHubRepo = gitHubRepo
        self.botConfigTemplate = botConfigTemplate
    }
    
    func sync(completion:(error:NSError?) -> ()) {

        let (botPRPairs, error) = getBotPRPairs()
        if let error = error {
            completion(error:error)
            return
        }

        if let error = deleteXBots(botPRPairs) {
            completion(error:error)
            return
        }

        if let error = createXBots(botPRPairs) {
            completion(error:error)
            return
        }


        if let error = syncXBots(botPRPairs) {
            completion(error:error)
            return
        }

        //TODO: "Retest"
        //TODO: add new commit

        completion(error: nil)
    }
    
    //MARK: Private
    private func getBotPRPairs() -> ([BotPRPair],NSError?) {
        var prs:[GitHubPullRequest] = []
        var bots:[Bot] = []
        var error:NSError? = nil

        var prFinished = false
        var botFinished = false
        var finishedBoth:() -> (Bool) = { return prFinished && botFinished }
        
        gitHubRepo.fetchPullRequests { (fetchedPRs, fetchError)  in
            prs = fetchedPRs
            error = fetchError
            prFinished = true
        }
        
        botServer.fetchBots({ (fetchedBots) in
            bots = fetchedBots
            //TODO: return error?
            botFinished = true
        })
        
        if waitForTimeout(10, finishedBoth) {
            var whatFailed = prFinished ? "bots" : "github"
            var errorMessage = "Timeout waiting for \(whatFailed)"

            error = NSError(domain:"GitHubXBotSyncDomain",
                code:10001,
                userInfo:[NSLocalizedDescriptionKey:errorMessage])
        }

        return (combinePrs(prs, withBots:bots), error)
    }

    private func combinePrs(prs:[GitHubPullRequest], withBots bots:[Bot]) -> ([BotPRPair]) {
        var botPRPairs:[BotPRPair] = []
        for pr in prs {
            if pr.sha == nil || pr.branch == nil || pr.title == nil {continue}

            var pair = BotPRPair(bot:nil, pr:pr)
            let matchingBots = bots.filter{ $0.name == pr.xBotTitle }
            if let matchedBot = matchingBots.first {
                pair.bot = matchedBot
            }

            botPRPairs.append(pair)
        }

        for bot in bots {
            let matchingPairs = botPRPairs.filter{ if let existingName = $0.bot?.name { return existingName == bot.name } else { return false} }
            if matchingPairs.count == 0 {
                var pair = BotPRPair(bot:bot, pr:nil)
                botPRPairs.append(pair)
            }
        }
        return botPRPairs
    }

    private func deleteXBots(gitXBotInfos:[BotPRPair]) -> (NSError?){
        let botsToDelete = gitXBotInfos.filter{$0.pr == nil}
        var error:NSError?

        for botToDelete in botsToDelete {
            var finished = false
            println("Deleting bot \(botToDelete.bot?.name)")
            botToDelete.bot?.delete{ (success) in
                if !success {
                    var errorMessage = "Unable to delete bot \(botToDelete.bot?.name)"

                    error = NSError(domain:"GitHubXBotSyncDomain",
                        code:10001,
                        userInfo:[NSLocalizedDescriptionKey:errorMessage])

                }

                finished = true
            }

            if waitForTimeout(10, &finished) {
                var errorMessage = "Timeout waiting to delete bot \(botToDelete.bot?.name)"

                error = NSError(domain:"GitHubXBotSyncDomain",
                    code:10001,
                    userInfo:[NSLocalizedDescriptionKey:errorMessage])
            }

            if let error = error {return error}
        }
        return error
    }
    
    //go through each PR, create XBot (and start integration) if not present
    private func createXBots(gitXBotInfos:[BotPRPair]) -> (NSError?) {
        let botsToCreate = gitXBotInfos.filter{$0.bot == nil}
        var error:NSError?

        for botToCreate in botsToCreate {
            var finished = false
            println("Creating bot from PR: \(botToCreate.pr?.xBotTitle)")
            
            var botConfig = XBot.BotConfiguration(
                name:botToCreate.pr!.xBotTitle,
                projectOrWorkspace:botConfigTemplate.projectOrWorkspace,
                schemeName:botConfigTemplate.schemeName,
                gitUrl:"git@github.com:\(gitHubRepo.repoName).git",
                branch:botToCreate.pr!.branch!,
                publicKey:botConfigTemplate.publicKey,
                privateKey:botConfigTemplate.privateKey,
                deviceIds:botConfigTemplate.deviceIds
            )
            
            botConfig.performsTestAction = botConfigTemplate.performsTestAction
            botConfig.performsAnalyzeAction = botConfigTemplate.performsAnalyzeAction
            botConfig.performsArchiveAction = botConfigTemplate.performsArchiveAction
            
            botServer.createBot(botConfig){ (success, bot) in
                let status = success ? "COMPLETED" : "FAILED"
                println("\(bot?.name) (\(bot?.id)) creation \(status)")

                if success {
                    bot?.integrate { (success, integration) in
                        let status = success ? integration?.currentStep ?? "NO INTEGRATION STEP" : "FAILED"
                        println("\(bot?.name) (\(bot?.id)) integration - \(status)")
                        self.gitHubRepo.setStatus(.Pending, sha: botToCreate.pr!.sha!){ }
                    }
                } else {
                    var errorMessage = "Unable to create bot \(botToCreate.bot?.name)"

                    error = NSError(domain:"GitHubXBotSyncDomain",
                        code:10001,
                        userInfo:[NSLocalizedDescriptionKey:errorMessage])
                }
                finished = true
            }

            if waitForTimeout(10, &finished) {
                var errorMessage = "Timeout waiting to create bot \(botToCreate.bot?.name)"

                error = NSError(domain:"GitHubXBotSyncDomain",
                    code:10001,
                    userInfo:[NSLocalizedDescriptionKey:errorMessage])
            }

            if let error = error {return error}
        }

        return error
    }
    
    //go through each XBot, update PR status as required
    private func syncXBots(gitXBotInfos:[BotPRPair]) -> (NSError?) {
        let botsToSync = gitXBotInfos.filter{$0.bot != nil && $0.pr != nil}
        var error:NSError?

        for botToSync in botsToSync {
            let bot = botToSync.bot!
            let pr = botToSync.pr!
            var finished = false
            bot.fetchLatestIntegration{ (latestIntegration) in
                if let latestIntegration = latestIntegration {
                    println("Syncing Status: \(bot.name) #\(latestIntegration.number) \(latestIntegration.currentStep) \(latestIntegration.result)")
                    let expectedStatus = CommitStatus.fromXBotStatusText(latestIntegration.result)
                    self.gitHubRepo.getStatus(pr.sha!){ (currentStatus) in
                        if currentStatus == .NoStatus {

                            bot.integrate { (success, integration) in
                                let status = success ? integration?.currentStep ?? "NO INTEGRATION STEP" : "FAILED"
                                println("\(bot.name) integration for sha \(pr.sha!) - \(status)")
                                self.gitHubRepo.setStatus(.Pending, sha: pr.sha!){ }
                            }

                        } else if expectedStatus != currentStatus {
                            println("Updating status of \(bot.name) to \(expectedStatus.rawValue)")
                            self.gitHubRepo.setStatus(expectedStatus, sha: pr.sha!){
                                self.gitHubRepo.addComment(pr.number!, text:latestIntegration.summaryString) {
                                    println("added comment")
                                    println(latestIntegration.summaryString)
                                }
                            }
                        } else {
                            println("Status unchanged: \(expectedStatus.rawValue)")
                        }
                        finished = true
                    }
                    
                } else {
                    finished = true
                }
            }

            if waitForTimeout(10, &finished) {
                var errorMessage = "Timeout waiting to get bot status \(bot.name)"

                error = NSError(domain:"GitHubXBotSyncDomain",
                    code:10001,
                    userInfo:[NSLocalizedDescriptionKey:errorMessage])
            }

            if let error = error {return error}
        }
        return error
    }
    
}


