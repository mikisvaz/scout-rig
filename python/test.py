if __name__ == "__main__":
    import sys
    sys.path.append('python')
    import scout
    import scout.workflow
    wf = scout.workflow.Workflow('Baking')
    step = wf.fork('bake_muffin_tray', add_blueberries=True, clean='recursive')
    step.join()
    print(step.load())



